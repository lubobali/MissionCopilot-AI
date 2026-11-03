import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// Downloading a mission pack before going offline (#91, threat T51), against a stand-in for the server
/// that serves the real signed Kandor pack. Every request is signed afresh; a lost signal pauses the
/// download and the next run goes on from the bytes already on the phone; nothing is used unless the
/// signature, the rules, the version and every file check out.
@Suite(.timeLimit(.minutes(1)))  // a download that never ends is a failure, not a hang
struct PackDownloaderTests {
    static let mission = "6f1d2c3a-0000-4000-8000-000000000001"
    static let org = "kandor-works"
    static let packBytes = 8_921  // the twelve files of the fixture

    /// Everything one download needs, on a fresh phone: the client, the store and the staging folder.
    final class Rig: @unchecked Sendable {
        let server = FakePackServer()
        let store: MissionStore
        let staging: PackStaging
        let service = "missioncopilot.tests.pack.\(UUID().uuidString)"
        var keys: [P256.Signing.PublicKey] = [PackVerifierTests.fixtureKey]
        var space: Int64 = 1 << 30
        private(set) var states: [PackDownloadState] = []
        private let lock = NSLock()

        init() throws {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            store = MissionStore(store: try EncryptedStore.open(at: temp.appendingPathExtension("sqlite"),
                                                                key: DataKey.random()),
                                 vault: SoftwareKeyVault())
            staging = try PackStaging(base: temp, mission: PackDownloaderTests.mission)
        }

        func run(chunk: Int = 256) async -> PackOutcome {
            let client = ServerClient(base: URL(string: "https://kandor-works.example.org")!,
                                      deviceId: "6f1d2c3a-1111-4000-8000-000000000007",
                                      signer: SoftwareEvidenceSigner(),
                                      counter: RequestCounter(items: KeychainItems(service: service), account: "phone"),
                                      transport: server)
            let pinned = keys, space = space
            let lookup: @Sendable (String) -> P256.Signing.PublicKey? = { id in
                pinned.first { ServerConfig.keyId($0.derRepresentation) == id }
            }
            let downloader = PackDownloader(client: client, keys: lookup, store: store,
                                            staging: staging, chunk: chunk, freeSpace: { space },
                                            now: { PackVerifierTests.now }, appVersion: "0.5.0",
                                            onState: { state in self.lock.withLock { self.states.append(state) } })
            return await downloader.run(org: PackDownloaderTests.org, mission: PackDownloaderTests.mission)
        }

        /// Every staged file is byte for byte the server's.
        func stagedAsServed() throws -> Bool {
            let manifest = try PackVerifier.verify(manifest: FakePackServer.file("manifest.json"),
                                                   signature: FakePackServer.file("signature.json"),
                                                   keys: PackVerifierTests.pinned(keys), now: PackVerifierTests.now,
                                                   appVersion: "0.5.0")
            return try manifest.files.allSatisfy { try staging.ready($0) == FakePackServer.file("files/\($0.sha256)") }
        }
    }

    private func isVerified(_ outcome: PackOutcome) -> Bool {
        if case .verified = outcome { return true }
        return false
    }

    // The whole pack

    @Test(.needsRepoFiles) func theWholeKandorPackDownloadsInPiecesAndVerifies() async throws {
        let rig = try Rig()

        let outcome = await rig.run()

        guard case .verified(let ready) = outcome else { Issue.record("\(outcome)"); return }
        #expect(ready.manifest.missionId == Self.mission && ready.manifest.files.count == 12)
        #expect(ready.manifestBytes == FakePackServer.file("manifest.json"))
        #expect(try rig.stagedAsServed())
        #expect(rig.server.bytesSent == Self.packBytes)
        #expect(rig.server.fileRequests > 12)  // pieces of 256 bytes, not whole files
        #expect(rig.states.first == .checking && rig.states.last == .verified)
        #expect(rig.states.contains(.downloading(done: Self.packBytes, total: Self.packBytes)))
    }

    @Test(.needsRepoFiles) func everyRequestIsSignedAfreshWithARisingNumber() async throws {
        let rig = try Rig()

        _ = await rig.run()

        let seqs = rig.server.requests.compactMap { $0.value(forHTTPHeaderField: "X-Device-Seq").flatMap(Int.init) }
        let signatures = Set(rig.server.requests.compactMap { $0.value(forHTTPHeaderField: "X-Device-Signature") })
        #expect(seqs.count == rig.server.requests.count && seqs == seqs.sorted() && Set(seqs).count == seqs.count)
        #expect(signatures.count == rig.server.requests.count)
    }

    @Test(.needsRepoFiles) func aSecondRunAfterAFinishedOneFetchesNoFile() async throws {
        let rig = try Rig()
        _ = await rig.run()
        let before = rig.server.fileRequests

        #expect(isVerified(await rig.run()))
        #expect(rig.server.fileRequests == before)
    }

    // A lost signal, and servers that answer differently

    @Test(.needsRepoFiles, arguments: [true, false])  // cut off during a request, or between two
    func aDownloadStoppedByTheSystemPausesAndTheNextRunGoesOn(duringARequest: Bool) async throws {
        let rig = try Rig()
        rig.server.cancelCutsOff = duringARequest
        let holder = TaskHolder()
        rig.server.onFileRequest = { number in if number == 9 { holder.cancel() } }
        let first = Task { await rig.run() }
        holder.set(first)

        #expect(await first.value == .paused(.interrupted))
        rig.server.onFileRequest = nil
        #expect(isVerified(await rig.run()))
        #expect(try rig.stagedAsServed())
    }

    @Test(.needsRepoFiles) func aLostSignalPausesAndTheNextRunGoesOnWithoutFetchingAgain() async throws {
        let rig = try Rig()
        rig.server.dropOnce = 9

        #expect(await rig.run() == .paused(.offline))
        #expect(rig.states.last == .paused(.offline))
        #expect(rig.server.bytesSent > 0 && rig.server.bytesSent < Self.packBytes)
        let next = rig.server.requests.count

        #expect(isVerified(await rig.run()))
        #expect(rig.server.bytesSent == Self.packBytes)  // not one byte twice
        let resumed = rig.server.requests[next...].first { $0.url?.path().contains("/files/") == true }
        #expect(resumed?.value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=0-") == false)
        #expect(try rig.stagedAsServed())
    }

    @Test(.needsRepoFiles) func aServerThatIgnoresRangeStillGivesTheRightFiles() async throws {
        let rig = try Rig()
        rig.server.ignoreRange = true

        #expect(isVerified(await rig.run()))
        #expect(try rig.stagedAsServed())
        #expect(rig.server.fileRequests == 12)
    }

    @Test(.needsRepoFiles) func aRangeOutsideTheFileStartsThatFileOver() async throws {
        let rig = try Rig()
        let first = try #require(try PackVerifier.rules(JSONSerialization.jsonObject(
            with: FakePackServer.file("manifest.json"))).files.first)
        rig.server.rangeOutsideOnce = [first.sha256]

        #expect(isVerified(await rig.run()))
        #expect(try rig.stagedAsServed())
    }

    @Test(.needsRepoFiles) func aServerThatAlwaysAnswersOutsideTheFileFailsInsteadOfAskingForever() async throws {
        let rig = try Rig()
        let first = try #require(try PackVerifier.rules(JSONSerialization.jsonObject(
            with: FakePackServer.file("manifest.json"))).files.first)
        rig.server.rangeOutsideAlways = [first.sha256]

        #expect(await rig.run() == .failed(.badFile(first.path)))
        #expect(rig.server.fileRequests == 2)
    }

    @Test(.needsRepoFiles) func aFileThatArrivesChangedOnceIsFetchedAgain() async throws {
        let rig = try Rig()
        let first = try #require(try PackVerifier.rules(JSONSerialization.jsonObject(
            with: FakePackServer.file("manifest.json"))).files.first)
        rig.server.corrupt = [first.sha256: 1]

        #expect(isVerified(await rig.run()))
        #expect(try rig.stagedAsServed())
    }

    @Test(.needsRepoFiles) func aFileThatStaysChangedFailsTheDownloadAndIsNotKept() async throws {
        let rig = try Rig()
        let first = try #require(try PackVerifier.rules(JSONSerialization.jsonObject(
            with: FakePackServer.file("manifest.json"))).files.first)
        rig.server.corrupt = [first.sha256: 1_000]

        #expect(await rig.run() == .failed(.badFile(first.path)))
        #expect(!rig.staging.isReady(first))
        #expect(try rig.staging.partialSize(of: first) == 0)
    }

    // The manifest and its signature

    @Test(.needsRepoFiles) func aPackPublishedBetweenManifestAndSignatureIsFetchedOnceMore() async throws {
        let rig = try Rig()
        rig.server.publishInBetween = 1

        #expect(isVerified(await rig.run()))
    }

    @Test(.needsRepoFiles) func aSignatureThatStaysWrongIsRefusedBeforeAnyFile() async throws {
        let rig = try Rig()
        rig.server.publishInBetween = 2

        #expect(await rig.run() == .failed(.refused(.badSignature)))
        #expect(rig.server.fileRequests == 0)
    }

    @Test(.needsRepoFiles) func aPackFromAKeyThatIsNotPinnedIsRefusedBeforeAnyFile() async throws {
        let rig = try Rig()
        rig.keys = [P256.Signing.PrivateKey().publicKey]

        #expect(await rig.run() == .failed(.refused(.unknownKey)))
        #expect(rig.server.fileRequests == 0)
    }

    @Test(.needsRepoFiles) func anOlderPackThanTheLastAcceptedIsRefusedBeforeAnyFile() async throws {
        let rig = try Rig()
        try rig.store.recordAcceptedPack(AcceptedPack(version: 2, manifestSHA256: String(repeating: "0", count: 64)),
                                         for: Self.mission)

        #expect(await rig.run() == .failed(.refused(.older)))
        #expect(rig.server.fileRequests == 0)
    }

    @Test(.needsRepoFiles) func notEnoughRoomForThreeTimesThePackFailsBeforeAnyFile() async throws {
        let rig = try Rig()
        rig.space = Int64(Self.packBytes) * 3 - 1

        #expect(await rig.run() == .failed(.notEnoughSpace(needed: Int64(Self.packBytes) * 3,
                                                          available: Int64(Self.packBytes) * 3 - 1)))
        #expect(rig.server.fileRequests == 0)
    }

    // What the server says about this phone

    @Test(.needsRepoFiles, arguments: [(401, PackOutcome.failed(.notApproved)), (404, .failed(.notFound)),
                                       (429, .paused(.slowDown(60))), (500, .failed(.server(500)))])
    func theServersAnswerAboutThisPhoneEndsTheRun(status: Int, expected: PackOutcome) async throws {
        let rig = try Rig()
        rig.server.manifestStatus = (status, Data())

        #expect(await rig.run() == expected)
        #expect(rig.server.fileRequests == 0)
    }

    @Test(.needsRepoFiles) func aShredOrderIsHandedOnUntouched() async throws {
        let rig = try Rig()
        let order = FakePackServer.file("../shred-order.json")
        rig.server.manifestStatus = (410, order)

        #expect(await rig.run() == .shredOrder(order))
    }
}

/// Lets a fake server stop the download it is serving, as the system does when it wants the time back.
final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<PackOutcome, Never>?
    private var cancelled = false

    func set(_ task: Task<PackOutcome, Never>) {
        lock.withLock {
            self.task = task
            if cancelled { task.cancel() }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            task?.cancel()
        }
    }
}
