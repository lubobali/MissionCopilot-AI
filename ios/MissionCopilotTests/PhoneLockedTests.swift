import Foundation
import Security
import Testing
@testable import MissionCopilot

/// A phone locked in the middle of a download (#94, 94.0). The chip key and the request counter work only
/// while the phone is unlocked (kept: that is the security), so a locked phone cannot sign the next piece:
/// the Keychain answers errSecInteractionNotAllowed. That is a pause, never a failure: nothing is sent, the
/// bytes on the phone stay, and the download goes on when the app is opened again.
@MainActor @Suite(.serialized) struct PhoneLockedTests {
    /// A signer the test can lock, failing as a locked iPhone does.
    final class LockableSigner: EvidenceSigner, @unchecked Sendable {
        private let real = SoftwareEvidenceSigner()
        private let lock = NSLock()
        private var signed = 0
        private var lockAfter: Int?
        var error: Error = KeychainFailure(status: errSecInteractionNotAllowed)

        func lock(after signatures: Int = 0) { lock.withLock { lockAfter = signed + signatures } }
        func unlock() { lock.withLock { lockAfter = nil } }

        func publicKeyDER() throws -> Data { try real.publicKeyDER() }

        func sign(_ message: Data) throws -> Data {
            let locked = lock.withLock { () -> Bool in
                if let lockAfter, signed >= lockAfter { return true }
                signed += 1
                return false
            }
            if locked { throw error }
            return try real.sign(message)
        }
    }

    let service = "missioncopilot.tests.locked.\(UUID().uuidString)"

    private func client(_ transport: FakeTransport, signer: EvidenceSigner) -> ServerClient {
        ServerClient(base: URL(string: "https://kandor-works.example.org")!, deviceId: "device-1", signer: signer,
                     counter: RequestCounter(items: KeychainItems(service: service), account: "device-1"),
                     transport: transport)
    }

    @Test(arguments: [KeychainFailure(status: errSecInteractionNotAllowed) as Error,
                      NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))])
    func aLockedPhoneIsItsOwnAnswerAndSendsNothing(error: Error) async {
        let signer = LockableSigner()
        signer.error = error
        signer.lock()
        let transport = FakeTransport(status: 200)

        let outcome = await client(transport, signer: signer).get("/v1/missions")

        #expect(outcome == .phoneLocked)
        #expect(outcome.kind == .phoneLocked)
        #expect(transport.sent.isEmpty)
    }

    @Test func anyOtherSigningFailureIsStillNotSent() async {
        let signer = LockableSigner()
        signer.error = KeychainFailure(status: errSecAuthFailed)
        signer.lock()

        #expect(await client(FakeTransport(status: 200), signer: signer).get("/v1/missions") == .notSent)
    }

    @Test(.needsRepoFiles) func lockedHalfWayTheDownloadPausesKeepsItsBytesAndGoesOnUnlocked() async throws {
        let rig = try PackDownloaderTests.Rig()
        let signer = LockableSigner()
        rig.signer = signer
        signer.lock(after: 6)  // the manifest, its signature and four pieces, then the phone locks

        #expect(await rig.run() == .paused(.phoneLocked))
        let asked = rig.server.fileRequests
        #expect(asked == 4)
        signer.unlock()

        guard case .verified = await rig.run() else { Issue.record("not verified after unlock"); return }
        #expect(rig.server.bytesSent == PackDownloaderTests.packBytes)  // not one byte twice
    }

    @Test(.needsRepoFiles) func theListSaysItWaitsForTheUnlockAndGoesOnWhenTheAppOpens() async throws {
        let list = try MissionListModelTests()
        let signer = LockableSigner()
        let model = try list.model(signer: signer)
        await model.refresh()
        signer.lock(after: 6)

        model.download(MissionListModelTests.roads)
        await model.downloadsEnded()
        #expect(list.row(model, MissionListModelTests.roads)?.status == .paused(.phoneLocked))
        signer.unlock()
        await model.refresh()  // what the app does when it is opened and unlocked again
        await model.downloadsEnded()

        #expect(list.row(model, MissionListModelTests.roads)?.status == .ready(updated: MissionListModelTests.now))
    }

    @Test func theWordsSayItWaitsForTheUnlock() {
        #expect(MissionWordsTests.words.detail(.paused(.phoneLocked))
            == "Paused while the iPhone is locked. It goes on when you open the app again.")
        #expect(MissionRow.text(.paused(.phoneLocked))
            == "Update paused while the iPhone is locked. It goes on when you open the app again.")
    }
}
