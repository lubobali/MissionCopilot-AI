import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// The real network to the local server, with what the end to end test needs on top: the signal lost
/// after a number of file requests, a log of every file request's Range, the manifest and signature
/// bytes as the server sent them, and, to play a man in the middle, older bytes answered in their place.
final class RecordingTransport: Transport, @unchecked Sendable {
    private let real = URLSessionTransport()
    private let lock = NSLock()
    private var cutAfter: Int?
    private var replayed: [String: Data] = [:]  // "manifest" / "signature" -> body
    private(set) var ranges: [String] = []
    private(set) var fetched: [String] = []  // the SHA-256 each file request asked for, in order
    private(set) var answered: [String: Data] = [:]

    func cut(after files: Int?) { lock.withLock { cutAfter = files.map { ranges.count + $0 } } }
    func replay(_ bodies: [String: Data]) { lock.withLock { replayed = bodies } }
    var fileRequests: Int { lock.withLock { ranges.count } }
    var fetchedFiles: [String] { lock.withLock { fetched } }
    var lastAnswered: [String: Data] { lock.withLock { answered } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path() ?? ""
        let part = path.hasSuffix("/pack/manifest") ? "manifest" : path.hasSuffix("/pack/signature") ? "signature" : nil
        let replay: Data? = try lock.withLock {
            if let part { return replayed[part] }
            guard path.contains("/pack/files/") else { return nil }
            if let cutAfter, ranges.count >= cutAfter { throw URLError(.networkConnectionLost) }
            ranges.append(request.value(forHTTPHeaderField: "Range") ?? "")
            fetched.append(String(path.split(separator: "/").last ?? ""))
            return nil
        }
        if let replay, let url = request.url,
           let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:]) {
            return (replay, response)
        }
        let (data, response) = try await real.send(request)
        if let part { lock.withLock { answered[part] = data } }
        return (data, response)
    }
}

/// The pack part of the end to end test (#91): the whole Kandor pack from the real server, cut off half
/// way and resumed from the bytes on the phone, a newer version taken, and the older one, played back
/// genuine and signed, refused. Markers in a folder the operator script also watches keep the two in step.
struct LocalServerPackSteps {
    let client: ServerClient, transport: RecordingTransport, config: ServerConfig
    let org: String, mission: String, signals: URL
    let store: MissionStore, staging: PackStaging

    init(client: ServerClient, transport: RecordingTransport, config: ServerConfig, org: String, mission: String,
         signals: URL) throws {
        self.client = client
        self.transport = transport
        self.config = config
        self.org = org
        self.mission = mission
        self.signals = signals
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = MissionStore(store: try EncryptedStore.open(at: temp.appendingPathExtension("sqlite"),
                                                            key: DataKey.random()),
                             vault: SoftwareKeyVault())
        staging = try PackStaging(base: temp, mission: mission)
    }

    private func download() async -> PackOutcome {
        let keys = config
        return await PackDownloader(client: client, keys: { keys.key(for: $0) }, store: store, staging: staging,
                                    chunk: 256, freeSpace: { PackDownloader.availableSpace(at: FileManager.default
                                        .temporaryDirectory) })
            .run(org: org, mission: mission)
    }

    private func accepted(_ outcome: PackOutcome) throws -> PackReady {
        guard case .verified(let ready) = outcome else { throw E2EStop.outcome("\(outcome)") }
        try PackAcceptance.record(ready.manifest, manifestBytes: ready.manifestBytes, in: store)
        return ready
    }

    func signal(_ name: String) throws { try Data().write(to: signals.appending(path: name)) }

    /// Returns the newest version taken, for the mission list step.
    func run() async throws -> Int {
        // 1. The signal is lost after eight pieces; the next run goes on from the bytes on the phone.
        transport.cut(after: 8)
        #expect(await download() == .paused(.offline))
        let before = transport.fileRequests
        transport.cut(after: nil)
        let first = try accepted(await download())
        #expect(transport.ranges[before].hasPrefix("bytes=0-") == false, "resumed from the bytes on the phone")
        let old = transport.lastAnswered
        for file in first.manifest.files { try PackVerifier.check(file, data: try staging.ready(file)) }

        // 2. The operator publishes the next version: taken, with no file fetched twice.
        try signal("first-pack")
        let fetched = transport.fileRequests
        var newer: PackReady?
        for _ in 0..<120 where newer == nil {
            if case .verified(let ready) = await download(), ready.manifest.version > first.manifest.version {
                newer = try accepted(.verified(ready))
            } else {
                try await Task.sleep(for: .seconds(1))
            }
        }
        #expect(newer?.manifest.version == first.manifest.version + 1)
        // Only files the first pack did not have are fetched: none is fetched twice (a newer pack may
        // change some files, as one that changes its checklist does).
        let again = Set(transport.fetchedFiles.dropFirst(fetched)).intersection(first.manifest.files.map(\.sha256))
        #expect(again.isEmpty, "fetched again: \(again)")
        let changed = Set(newer?.manifest.files.map(\.sha256) ?? []).subtracting(first.manifest.files.map(\.sha256))
        #expect(Set(transport.fetchedFiles.dropFirst(fetched)) == changed, "only the changed files")

        // 3. The older pack, genuine and signed, played back in the middle: refused before any file.
        let files = transport.fileRequests
        transport.replay(old)
        #expect(await download() == .failed(.refused(.older)))
        #expect(transport.fileRequests == files)
        transport.replay([:])
        return newer?.manifest.version ?? first.manifest.version
    }
}

enum E2EStop: Error { case outcome(String) }
