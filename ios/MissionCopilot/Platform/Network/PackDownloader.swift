import CryptoKit
import Foundation

/// Downloads a mission pack before going offline (#91). Every request is built and signed afresh by
/// ServerClient: never a background session, which would replay an old signed request that the server
/// rightly refuses. The manifest and its signature come first and are checked (PackVerifier), then the
/// version (PackAcceptance) and the free space (three times what is still to come: half-done files,
/// finished files and the store). Files come one by one, in pieces of `chunk` bytes, each its own request
/// with Range and If-Range, appended to a half-done file, so a lost signal costs at most one piece and the
/// next run goes on from the bytes on disk. A file is kept only if it matches its entry; a wrong one is
/// fetched once more, then the run fails.
actor PackDownloader {
    private let client: ServerClient
    private let keys: @Sendable (String) -> P256Key?
    private let store: MissionStore
    private let staging: PackStaging
    private let chunk: Int
    private let freeSpace: @Sendable () -> Int64
    private let now: @Sendable () -> Date
    private let appVersion: String
    private let onState: @Sendable (PackDownloadState) -> Void

    typealias P256Key = P256.Signing.PublicKey

    init(client: ServerClient, keys: @escaping @Sendable (String) -> P256Key?, store: MissionStore,
         staging: PackStaging, chunk: Int = 1 << 20, freeSpace: @escaping @Sendable () -> Int64,
         now: @escaping @Sendable () -> Date = { Date() }, appVersion: String = PackVerifier.appVersion,
         onState: @escaping @Sendable (PackDownloadState) -> Void = { _ in }) {
        self.client = client
        self.keys = keys
        self.store = store
        self.staging = staging
        self.chunk = chunk
        self.freeSpace = freeSpace
        self.now = now
        self.appVersion = appVersion
        self.onState = onState
    }

    func run(org: String, mission: String) async -> PackOutcome {
        onState(.checking)
        let outcome = await download(org: org, mission: mission)
        switch outcome {
        case .verified: onState(.verified)
        case .paused(let pause): onState(.paused(pause))
        case .failed(let failure): onState(.failed(failure))
        case .shredOrder: break
        }
        return outcome
    }

    private func download(org: String, mission: String) async -> PackOutcome {
        let base = "/v1/missions/\(mission)/pack"
        var checked: (PackManifest, Data)?
        for _ in 0..<2 {  // a second time if a pack was published between the two requests
            let manifestAnswer = await client.get("\(base)/manifest")
            guard case .success(let manifest, _, _) = manifestAnswer else { return stopped(manifestAnswer) }
            let signatureAnswer = await client.get("\(base)/signature")
            guard case .success(let signature, _, _) = signatureAnswer else { return stopped(signatureAnswer) }
            do {
                checked = (try PackVerifier.verify(manifest: manifest, signature: signature, keys: keys, now: now(),
                                                   appVersion: appVersion), manifest)
                break
            } catch PackRefusal.badSignature {
                continue
            } catch {
                return .failed(.refused(error))
            }
        }
        guard let (pack, manifestBytes) = checked else { return .failed(.refused(.badSignature)) }
        do {
            try PackAcceptance.check(pack, manifestBytes: manifestBytes, asked: (org: org, mission: mission), in: store)
        } catch {
            return .failed(.refused(error))
        }
        return await files(of: pack, manifestBytes: manifestBytes, base: base)
    }

    private func files(of pack: PackManifest, manifestBytes: Data, base: String) async -> PackOutcome {
        let total = pack.files.reduce(0) { $0 + $1.size }
        var done = pack.files.reduce(0) { sum, file in
            sum + (staging.isReady(file) ? file.size : ((try? staging.partialSize(of: file)) ?? 0))
        }
        let needed = Int64(total - done) * 3, available = freeSpace()
        guard available >= needed else { return .failed(.notEnoughSpace(needed: needed, available: available)) }
        onState(.downloading(done: done, total: total))
        for file in pack.files where !staging.isReady(file) {
            if let stop = await fetch(file, base: base, done: &done, total: total) { return stop }
        }
        return .verified(PackReady(manifest: pack, manifestBytes: manifestBytes, staging: staging))
    }

    /// One file, piece by piece, then checked; nil when it is ready.
    private func fetch(_ file: PackFileEntry, base: String, done: inout Int, total: Int) async -> PackOutcome? {
        var wrong = 0, empty = 0  // a wrong file is fetched once more; two answers bringing nothing end it
        while true {
            guard let have = try? staging.partialSize(of: file) else { return .failed(.storage) }
            if have >= file.size {
                if (try? staging.finish(file)) != nil { return nil }
                done -= have
                wrong += 1
                if wrong > 1 { return .failed(.badFile(file.path)) }
                continue
            }
            switch await piece(of: file, from: have, base: base) {
            case .stop(let outcome):
                return outcome
            case .piece(let change, let progressed):
                done += change
                if !progressed { empty += 1 }
                if empty > 1 { return .failed(.badFile(file.path)) }
                onState(.downloading(done: done, total: total))
            }
        }
    }

    private enum Piece {
        case piece(change: Int, progressed: Bool)  // change: bytes on disk, up or (starting over) down
        case stop(PackOutcome)
    }

    /// The next piece of a file from byte `have`, signed afresh, written to its half-done file.
    private func piece(of file: PackFileEntry, from have: Int, base: String) async -> Piece {
        let last = min(have + chunk, file.size) - 1
        let headers = ["Range": "bytes=\(have)-\(last)", "If-Range": "\"\(file.sha256)\""]
        switch await client.get("\(base)/files/\(file.sha256)", headers: headers) {
        case .success(let data, 206, let answer) where answer["content-range"]?.hasPrefix("bytes \(have)-") == true:
            guard (try? staging.append(data, to: file)) != nil else { return .stop(.failed(.storage)) }
            return .piece(change: data.count, progressed: !data.isEmpty)
        case .success(let data, _, _):  // the whole file (Range ignored, or a different file): start over
            guard (try? staging.restart(file)) != nil, (try? staging.append(data, to: file)) != nil
            else { return .stop(.failed(.storage)) }
            return .piece(change: data.count - have, progressed: !data.isEmpty)
        case .rangeOutside:
            guard (try? staging.restart(file)) != nil else { return .stop(.failed(.storage)) }
            return .piece(change: -have, progressed: have > 0)
        case let other:
            return .stop(stopped(other))
        }
    }

    private func stopped(_ outcome: ServerClient.Outcome) -> PackOutcome {
        switch outcome {
        case .offline: .paused(.offline)
        case .slowDown(let seconds): .paused(.slowDown(seconds))
        case .refused: .failed(.notApproved)
        case .notFound: .failed(.notFound)
        case .shredOrder(let body): .shredOrder(body)
        case .failed(let status): .failed(.server(status))
        case .notSent, .rangeOutside: .failed(.server(0))
        case .success: .failed(.server(0))
        }
    }

    /// The space iOS will make for something the user asked for (not opportunistic space).
    static func availableSpace(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
