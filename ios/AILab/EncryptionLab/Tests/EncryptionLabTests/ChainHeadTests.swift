import Foundation
import Testing
@testable import EncryptionLab

struct ChainHeadTests {
    private let signer = SoftwareEvidenceSigner()
    private let start = Date(timeIntervalSince1970: 1_793_500_000)

    private func chain(_ files: [String], mission: String = "kandor-roads") throws -> EvidenceChain {
        var chain = EvidenceChain(missionId: mission)
        for (index, file) in files.enumerated() {
            try chain.append(file: Data(file.utf8), capturedAt: start.addingTimeInterval(Double(index) * 60),
                             signer: signer)
        }
        return chain
    }

    @Test func chainWithItsHeadVerifies() throws {
        let chain = try chain(["photo-km42", "photo-km43", "scan-invoice-6"])

        let result = EvidenceChain.verify(chain.records, head: try chain.signedHead(signer: signer),
                                          publicKeyDER: try signer.publicKeyDER())

        #expect(result == .valid(count: 3))
    }

    @Test func cutOffLastItemIsDetected() throws {
        let chain = try chain(["photo-km42", "photo-km43", "scan-invoice-6"])
        let head = try chain.signedHead(signer: signer)

        let result = EvidenceChain.verify(Array(chain.records.dropLast()), head: head,
                                          publicKeyDER: try signer.publicKeyDER())

        #expect(result == .brokenHead(.countMismatch))
    }

    @Test func changedHeadIsDetected() throws {
        let chain = try chain(["photo-km42", "photo-km43"])
        let head = try chain.signedHead(signer: signer)
        var payload = head.payload
        payload[payload.count - 3] ^= 0x01

        let result = EvidenceChain.verify(chain.records, head: EvidenceRecord(payload: payload, signature: head.signature),
                                          publicKeyDER: try signer.publicKeyDER())

        #expect(result == .brokenHead(.badSignature))
    }

    @Test func replacedLastItemDoesNotMatchTheHead() throws {
        let original = try chain(["photo-km42", "photo-km43", "scan-invoice-6"])
        let replaced = try chain(["photo-km42", "photo-km43", "scan-invoice-FAKE"])

        let result = EvidenceChain.verify(replaced.records, head: try original.signedHead(signer: signer),
                                          publicKeyDER: try signer.publicKeyDER())

        #expect(result == .brokenHead(.hashMismatch))
    }

    @Test func headOfAnotherMissionIsRejected() throws {
        let roads = try chain(["photo-km42"])
        let bridges = try chain(["photo-km42"], mission: "kandor-bridges")

        let result = EvidenceChain.verify(roads.records, head: try bridges.signedHead(signer: signer),
                                          publicKeyDER: try signer.publicKeyDER())

        #expect(result == .brokenHead(.wrongMission))
    }

    @Test func knownLimitOlderHeadWithMatchingCutChainStillVerifies() throws {
        // Pinned on purpose: on the phone alone, an OLD head plus a chain cut back to it looks valid.
        // Only an outside record of the latest head (the server's sync receipt, ADR 0006) can catch this.
        var chain = try chain(["photo-km42", "photo-km43"])
        let oldHead = try chain.signedHead(signer: signer)
        let olderRecords = chain.records
        try chain.append(file: Data("scan-invoice-6".utf8), capturedAt: start.addingTimeInterval(120), signer: signer)

        let result = EvidenceChain.verify(olderRecords, head: oldHead, publicKeyDER: try signer.publicKeyDER())

        #expect(result == .valid(count: 2))
    }
}
