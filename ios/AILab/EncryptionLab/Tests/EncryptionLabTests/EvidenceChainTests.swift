import CryptoKit
import Foundation
import Testing
@testable import EncryptionLab

struct EvidenceChainTests {
    private let signer = SoftwareEvidenceSigner()
    private let start = Date(timeIntervalSince1970: 1_793_500_000)

    private func chainOfThree() throws -> EvidenceChain {
        var chain = EvidenceChain(missionId: "kandor-roads")
        for (index, photo) in ["photo-km42", "photo-km43", "scan-invoice-6"].enumerated() {
            try chain.append(file: Data(photo.utf8), capturedAt: start.addingTimeInterval(Double(index) * 60),
                             signer: signer)
        }
        return chain
    }

    @Test func chainOfThreeVerifiesWithOnlyThePublicKey() throws {
        let chain = try chainOfThree()

        let result = EvidenceChain.verify(chain.records, publicKeyDER: try signer.publicKeyDER())

        #expect(result == .valid(count: 3))
    }

    @Test func oneChangedByteInAPayloadIsDetected() throws {
        var records = try chainOfThree().records
        var payload = records[1].payload
        payload[payload.count - 3] ^= 0x01
        records[1] = EvidenceRecord(payload: payload, signature: records[1].signature)

        let result = EvidenceChain.verify(records, publicKeyDER: try signer.publicKeyDER())

        #expect(result == .broken(at: 1, reason: .badSignature))
    }

    @Test func oneChangedByteInASignatureIsDetected() throws {
        var records = try chainOfThree().records
        var signature = records[2].signature
        signature[signature.count - 1] ^= 0x01
        records[2] = EvidenceRecord(payload: records[2].payload, signature: signature)

        let result = EvidenceChain.verify(records, publicKeyDER: try signer.publicKeyDER())

        #expect(result == .broken(at: 2, reason: .badSignature))
    }

    @Test func removedMiddleItemIsDetected() throws {
        var records = try chainOfThree().records
        records.remove(at: 1)

        let result = EvidenceChain.verify(records, publicKeyDER: try signer.publicKeyDER())

        #expect(result == .broken(at: 1, reason: .wrongPrevHash))
    }

    @Test func swappedItemsAreDetected() throws {
        var records = try chainOfThree().records
        records.swapAt(1, 2)

        let result = EvidenceChain.verify(records, publicKeyDER: try signer.publicKeyDER())

        #expect(result == .broken(at: 1, reason: .wrongPrevHash))
    }

    @Test func anotherSignersKeyRejectsTheFirstItem() throws {
        let records = try chainOfThree().records

        let result = EvidenceChain.verify(records, publicKeyDER: try SoftwareEvidenceSigner().publicKeyDER())

        #expect(result == .broken(at: 0, reason: .badSignature))
    }

    @Test func payloadIsSortedKeyJSONWithTheFileHash() throws {
        let file = Data("photo-km42".utf8)
        var chain = EvidenceChain(missionId: "kandor-roads")

        try chain.append(file: file, capturedAt: start, signer: signer)

        let hash = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
        let zeros = String(repeating: "0", count: 64)
        let expected = #"{"capturedAt":"2026-11-01T02:26:40Z","fileSHA256":"\#(hash)","missionId":"kandor-roads","#
            + #""prevHash":"\#(zeros)","seq":1}"#
        #expect(String(decoding: chain.records[0].payload, as: UTF8.self) == expected)
    }
}

struct EvidenceSequenceTests {
    @Test func correctlyLinkedButWronglyNumberedItemIsRejected() throws {
        // Signed by the right key with the right link, but numbered 5 instead of 1: only the seq check sees it.
        let signer = SoftwareEvidenceSigner()
        let payload = EvidencePayload(seq: 5, prevHash: EvidenceChain.genesisHash, fileSHA256: "ab",
                                      capturedAt: "2026-11-01T02:26:40Z", missionId: "kandor-roads")
        let bytes = try JSONEncoder().encode(payload)
        let record = EvidenceRecord(payload: bytes, signature: try signer.sign(bytes))

        let result = EvidenceChain.verify([record], publicKeyDER: try signer.publicKeyDER())

        #expect(result == .broken(at: 0, reason: .wrongSeq))
    }
}
