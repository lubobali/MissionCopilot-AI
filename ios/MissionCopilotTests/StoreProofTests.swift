import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

#if targetEnvironment(simulator)
// The Simulator uses the Mac's disk and reports no file protection; the phone run proves it.
private let simulatorGaps = ["file protection"]
#else
private let simulatorGaps: [String] = []
#endif

/// The phone proof of the Phase 4 store (#74), run here with software keys: every check passes on
/// working code, and a broken part makes its own check fail instead of passing by luck.
struct StoreProofTests {
    private struct Folders {
        let base: URL
        let outbox: URL
    }

    private func folders() throws -> Folders {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Folders(base: root.appendingPathComponent("StoreProof"), outbox: root.appendingPathComponent("outbox"))
    }

    private func proof(vault: any MissionKeyVault = SoftwareKeyVault(),
                       signer: any EvidenceSigner = SoftwareEvidenceSigner()) throws -> StoreProof {
        let folders = try folders()
        return StoreProof(base: folders.base, outbox: folders.outbox,
                          keys: KeychainDataKeyStore(service: "missioncopilot.tests.\(UUID().uuidString)",
                                                     access: DataKeyStoreTests.plainAccess),
                          vault: vault, signer: signer)
    }

    private func failed(_ report: StoreProofReport) -> [String] {
        report.checks.filter { !$0.passed }.map(\.name)
    }

    private func check(_ name: String, in report: StoreProofReport) -> StoreProofReport.Check? {
        report.checks.first { $0.name == name }
    }

    @Test func everyCheckPassesOnTheWorkingStore() throws {
        let proof = try proof()
        defer { proof.cleanUp() }

        let report = proof.run(device: "Simulator")

        #expect(report.checks.map(\.name) == StoreProof.checkNames)
        #expect(failed(report) == simulatorGaps, "\(report.checks.filter { !$0.passed })")
        #expect(report.passed == simulatorGaps.isEmpty)
    }

    @Test func theAuditLogCountsEveryChange() throws {
        let proof = try proof()
        defer { proof.cleanUp() }

        // 2 missions, 3 photos, 1 fact, 1 sentence, the ended lease's shred and the order's shred.
        #expect(check("audit log", in: proof.run())?.detail == "valid, 9 events")
    }

    @Test func aVaultThatNeverDestroysAKeyFailsTheShredChecks() throws {
        let proof = try proof(vault: KeptKeyVault())
        defer { proof.cleanUp() }

        let report = proof.run()

        #expect(check("lease ended", in: report)?.passed == false)
        #expect(check("shred order", in: report)?.passed == false)
        #expect(!report.passed)
    }

    @Test func aBrokenSignatureFailsTheChainCheck() throws {
        let proof = try proof(signer: BrokenSigner())
        defer { proof.cleanUp() }

        let report = proof.run()

        #expect(check("evidence chain", in: report)?.passed == false)
        #expect(!report.passed)
    }

    @Test func aStoreThatCannotOpenFailsEveryCheckWithoutCrashing() throws {
        let folders = try folders()
        let blocker = folders.base.deletingLastPathComponent().appendingPathComponent("a-file")
        try Data("not a folder".utf8).write(to: blocker)
        let proof = StoreProof(base: blocker.appendingPathComponent("StoreProof"), outbox: folders.outbox,
                               keys: KeychainDataKeyStore(service: "missioncopilot.tests.\(UUID().uuidString)",
                                                          access: DataKeyStoreTests.plainAccess),
                               vault: SoftwareKeyVault(), signer: SoftwareEvidenceSigner())
        defer { proof.cleanUp() }

        let report = proof.run()

        #expect(failed(report) == StoreProof.checkNames)
        #expect(report.checks.allSatisfy { $0.detail.hasPrefix("error: ") || $0.name == "export" })
    }

    @Test func aSecondRunStartsFresh() throws {
        let proof = try proof()
        defer { proof.cleanUp() }
        _ = proof.run()

        let again = proof.run()

        #expect(failed(again) == simulatorGaps)
        #expect(check("audit log", in: again)?.detail == "valid, 9 events")
    }

    @Test func theOutboxHoldsTheChainTheDatabaseAndTheResults() throws {
        let proof = try proof()
        defer { proof.cleanUp() }
        let report = proof.run(device: "Simulator")

        let names = try FileManager.default.contentsOfDirectory(atPath: proof.outbox.path)
        let results = try Data(contentsOf: proof.outbox.appendingPathComponent(StoreProof.resultsFile))
        let saved = try JSONDecoder().decode(StoreProofReport.self, from: results)
        let chain = try JSONSerialization.jsonObject(
            with: Data(contentsOf: proof.outbox.appendingPathComponent("evidence-chain.json"))) as? [String: Any]

        #expect(names.contains(UserStore.fileName))
        #expect(saved == report)
        #expect((chain?["records"] as? [Any])?.count == 3)
    }

    @Test func theCopiedDatabaseHoldsNoPlainText() throws {
        let proof = try proof()
        defer { proof.cleanUp() }
        _ = proof.run()

        let files = try FileManager.default.contentsOfDirectory(at: proof.outbox, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(UserStore.fileName) }
        let marker = Data(StoreProof.marker.utf8)

        #expect(!files.isEmpty)
        for file in files {
            #expect(try Data(contentsOf: file).range(of: marker) == nil, "\(file.lastPathComponent)")
        }
    }

    @Test func theAppsProofNeverUsesTheRealStoreOrKeys() {
        let live = StoreProof.live()

        #expect(live.base != UserStore.live.base)
        #expect(live.keys.service != UserStore.live.keys.service)
        #expect(StoreProof.vaultService != UserStore.live.vault.service)
        #expect(StoreProof.signerService != SecureEnclaveEvidenceSigner.appService)
    }
}

/// A vault whose destroy does nothing: shredded missions stay readable.
private final class KeptKeyVault: MissionKeyVault {
    private let inner = SoftwareKeyVault()

    func wrap(_ missionKey: SymmetricKey, for mission: String) throws -> WrappedMissionKey {
        try inner.wrap(missionKey, for: mission)
    }

    func unwrap(_ wrapped: WrappedMissionKey, for mission: String) throws -> SymmetricKey {
        try inner.unwrap(wrapped, for: mission)
    }

    func destroy(mission: String) throws {}
}

/// Signs, then changes one byte of the signature.
private struct BrokenSigner: EvidenceSigner {
    private let inner = SoftwareEvidenceSigner()

    func publicKeyDER() throws -> Data { try inner.publicKeyDER() }

    func sign(_ message: Data) throws -> Data {
        var signature = try inner.sign(message)
        signature[signature.count - 1] ^= 0x01
        return signature
    }
}
