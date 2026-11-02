import Foundation
import Testing
@testable import MissionCopilot

/// Evidence in the store (ADR 0008 and 0009, #71): each file and its signed record are sealed with the
/// mission's key, the chain continues across reopening, and a shred makes both unreadable at once.
struct EvidenceStoreTests {
    private let signer = SoftwareEvidenceSigner()

    private func missions(file: URL? = nil, key: DataKey? = nil, vault: SoftwareKeyVault = SoftwareKeyVault())
        throws -> MissionStore {
        let file = file ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: key ?? DataKey.random()), vault: vault)
        if try store.missionIDs().isEmpty { try store.create(mission: "kandor-roads", title: "Kandor rural roads") }
        return store
    }

    private func photo(_ name: String) -> Capture {
        EvidenceChainTests.capture(name)
    }

    @Test func threeCapturesMakeAChainThatVerifiesWithItsHead() throws {
        let store = try missions()
        for name in ["photo-km42", "photo-km43", "scan-invoice-6"] {
            try store.addEvidence(photo(name), to: "kandor-roads", signer: signer)
        }

        let chain = try store.evidence(in: "kandor-roads")
        let head = try #require(try store.evidenceHead(in: "kandor-roads"))

        #expect(EvidenceChain.verify(chain, head: head, publicKeyDER: try signer.publicKeyDER()) == .valid(count: 3))
    }

    @Test func theFileReadsBackAndIsSealedInTheDatabase() throws {
        let store = try missions()
        try store.addEvidence(photo("photo-km42"), to: "kandor-roads", signer: signer)

        #expect(try store.evidenceFile(in: "kandor-roads", seq: 1) == Data("photo-km42".utf8))
        let sealed = try store.sealedEvidence(in: "kandor-roads")
        #expect(sealed.count == 1)
        #expect(sealed[0].file.range(of: Data("photo-km42".utf8)) == nil)
        #expect(sealed[0].payload.range(of: Data("12345678".utf8)) == nil)  // the location is sealed too
    }

    @Test func theChainContinuesAfterTheStoreIsReopened() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let key = try DataKey.random()
        let vault = SoftwareKeyVault()
        try missions(file: file, key: key, vault: vault).addEvidence(photo("first"), to: "kandor-roads", signer: signer)

        let reopened = try missions(file: file, key: key, vault: vault)
        try reopened.addEvidence(photo("second"), to: "kandor-roads", signer: signer)

        let chain = try reopened.evidence(in: "kandor-roads")
        #expect(EvidenceChain.verify(chain, head: try #require(try reopened.evidenceHead(in: "kandor-roads")),
                                     publicKeyDER: try signer.publicKeyDER()) == .valid(count: 2))
    }

    @Test func aShredMakesTheFilesAndTheirRecordsUnreadable() throws {
        let store = try missions()
        try store.addEvidence(photo("photo-km42"), to: "kandor-roads", signer: signer)

        try store.shred(mission: "kandor-roads")

        #expect(throws: MissionKeyNotFound(mission: "kandor-roads")) { try store.evidence(in: "kandor-roads") }
        #expect(throws: MissionKeyNotFound(mission: "kandor-roads")) {
            try store.evidenceFile(in: "kandor-roads", seq: 1)
        }
        #expect(try store.sealedEvidence(in: "kandor-roads").count == 1)
    }

    @Test func purgeRemovesTheEvidenceAndItsHead() throws {
        let store = try missions()
        try store.addEvidence(photo("photo-km42"), to: "kandor-roads", signer: signer)
        try store.shred(mission: "kandor-roads")

        try store.purge(mission: "kandor-roads")

        #expect(try store.sealedEvidence(in: "kandor-roads").isEmpty)
        #expect(try store.evidenceHead(in: "kandor-roads") == nil)
    }

    @Test func theExportHasTheShapeThePythonVerifierLoads() throws {
        let store = try missions()
        try store.addEvidence(photo("photo-km42"), to: "kandor-roads", signer: signer)

        let json = try JSONSerialization.jsonObject(with: store.exportEvidence(of: "kandor-roads", signer: signer))
        let export = try #require(json as? [String: Any])

        #expect(Set(export.keys) == ["publicKeyDER", "records", "head"])
        #expect((export["records"] as? [[String: String]])?.first.map { Set($0.keys) } == ["payload", "signature"])
        #expect(Data(base64Encoded: export["publicKeyDER"] as? String ?? "") == (try signer.publicKeyDER()))
    }

    @Test func evidenceForAMissingMissionIsRefused() throws {
        #expect(throws: MissionKeyNotFound(mission: "nowhere")) {
            try missions().addEvidence(photo("x"), to: "nowhere", signer: signer)
        }
    }
}
