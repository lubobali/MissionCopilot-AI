import Foundation
import Testing
@testable import MissionCopilot

/// The signed head, re-signed after every item, catches a cut-off last item the chain alone cannot see
/// (ADR 0009, #71). Its known limit is tested too, so it stays written down.
struct ChainHeadTests {
    private let signer = SoftwareEvidenceSigner()

    private func chain(_ count: Int, mission: String = "kandor-roads") throws -> EvidenceChain {
        var chain = EvidenceChain(missionId: mission)
        for index in 0..<count {
            try chain.append(EvidenceChainTests.capture("item-\(index)", minute: index), signer: signer)
        }
        return chain
    }

    private func verify(_ records: [EvidenceRecord], _ head: EvidenceRecord) throws -> EvidenceChain.Verification {
        EvidenceChain.verify(records, head: head, publicKeyDER: try signer.publicKeyDER())
    }

    @Test func aChainWithItsHeadVerifies() throws {
        let chain = try chain(3)

        #expect(try verify(chain.records, chain.signedHead(signer: signer)) == .valid(count: 3))
    }

    @Test func aCutOffLastItemIsDetected() throws {
        let chain = try chain(3)

        #expect(try verify(Array(chain.records.dropLast()), chain.signedHead(signer: signer))
            == .brokenHead(.countMismatch))
    }

    @Test func aChangedHeadIsDetected() throws {
        let head = try chain(3).signedHead(signer: signer)
        var payload = head.payload
        payload[payload.count - 3] ^= 0x01

        #expect(try verify(chain(3).records, EvidenceRecord(payload: payload, signature: head.signature))
            == .brokenHead(.badSignature))
    }

    @Test func aReplacedLastItemDoesNotMatchTheHead() throws {
        let original = try chain(3)
        var replaced = EvidenceChain(missionId: "kandor-roads")
        for record in original.records.dropLast() { replaced.adopt(record) }
        try replaced.append(EvidenceChainTests.capture("forged", minute: 9), signer: signer)

        #expect(try verify(replaced.records, original.signedHead(signer: signer)) == .brokenHead(.hashMismatch))
    }

    @Test func aHeadOfAnotherMissionIsRejected() throws {
        #expect(try verify(chain(2).records, chain(2, mission: "kandor-bridges").signedHead(signer: signer))
            == .brokenHead(.wrongMission))
    }

    @Test func knownLimitAnOlderHeadWithAChainCutBackToItStillVerifies() throws {
        // Only the server's record of the latest head (ADR 0006) catches this.
        let older = try chain(2)
        let head = try older.signedHead(signer: signer)

        #expect(try verify(older.records, head) == .valid(count: 2))
    }
}
