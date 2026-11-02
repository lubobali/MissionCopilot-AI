import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// Hash-chained, signed evidence (ADR 0009, #71), from spike #17 with payload v2: changing one byte,
/// removing, swapping or renumbering an item is detected offline with only the public key.
struct EvidenceChainTests {
    private let signer = SoftwareEvidenceSigner()
    static let start = Date(timeIntervalSince1970: 1_794_476_400)

    static func capture(_ name: String, minute: Int = 0, kind: EvidencePayload.Kind = .photo) -> Capture {
        Capture(file: Data(name.utf8), kind: kind, capturedAt: start.addingTimeInterval(Double(minute) * 60),
                clockSource: .device, location: EvidencePayload.Location(latE6: 12_345_678, lonE6: -23_456_789))
    }

    private func chainOfThree() throws -> EvidenceChain {
        var chain = EvidenceChain(missionId: "kandor-roads")
        for (index, name) in ["photo-km42", "photo-km43", "scan-invoice-6"].enumerated() {
            try chain.append(Self.capture(name, minute: index), signer: signer)
        }
        return chain
    }

    private func verify(_ records: [EvidenceRecord]) throws -> EvidenceChain.Verification {
        EvidenceChain.verify(records, publicKeyDER: try signer.publicKeyDER())
    }

    @Test func aChainOfThreeVerifiesWithOnlyThePublicKey() throws {
        #expect(try verify(chainOfThree().records) == .valid(count: 3))
    }

    @Test func oneChangedByteInAPayloadIsDetected() throws {
        var records = try chainOfThree().records
        var payload = records[1].payload
        payload[payload.count - 3] ^= 0x01
        records[1] = EvidenceRecord(payload: payload, signature: records[1].signature)

        #expect(try verify(records) == .broken(item: 1, reason: .badSignature))
    }

    @Test func oneChangedByteInASignatureIsDetected() throws {
        var records = try chainOfThree().records
        var signature = records[2].signature
        signature[signature.count - 1] ^= 0x01
        records[2] = EvidenceRecord(payload: records[2].payload, signature: signature)

        #expect(try verify(records) == .broken(item: 2, reason: .badSignature))
    }

    @Test func aRemovedOrSwappedItemIsDetected() throws {
        var removed = try chainOfThree().records
        removed.remove(at: 1)
        var swapped = try chainOfThree().records
        swapped.swapAt(1, 2)

        #expect(try verify(removed) == .broken(item: 1, reason: .wrongPrevHash))
        #expect(try verify(swapped) == .broken(item: 1, reason: .wrongPrevHash))
    }

    @Test func anotherSignersKeyRejectsTheFirstItem() throws {
        let records = try chainOfThree().records

        #expect(EvidenceChain.verify(records, publicKeyDER: try SoftwareEvidenceSigner().publicKeyDER())
            == .broken(item: 0, reason: .badSignature))
    }

    @Test func thePayloadSignsKindClockSourceAndLocation() throws {
        var chain = EvidenceChain(missionId: "kandor-roads")
        try chain.append(Self.capture("photo-km42"), signer: signer)

        let hash = SHA256.hash(data: Data("photo-km42".utf8)).map { String(format: "%02x", $0) }.joined()
        let expected = #"{"capturedAt":"2026-11-12T09:40:00Z","clockSource":"device","contentHash":"\#(hash)","#
            + #""kind":"photo","location":{"latE6":12345678,"lonE6":-23456789},"missionId":"kandor-roads","#
            + #""prevHash":"\#(EvidenceChain.genesisHash)","seq":1,"v":2}"#
        #expect(String(bytes: chain.records[0].payload, encoding: .utf8) == expected)
    }

    @Test func aCorrectlyLinkedButWronglyNumberedItemIsRejected() throws {
        // Right key, right link, numbered 5 instead of 1: only the sequence check sees it.
        let payload = EvidencePayload(seq: 5, prevHash: EvidenceChain.genesisHash,
                                      contentHash: String(repeating: "a", count: 64), kind: .photo,
                                      capturedAt: "2026-11-12T09:40:00Z", clockSource: .device,
                                      location: nil, missionId: "kandor-roads")
        let bytes = try EvidenceChain.encoder.encode(payload)

        #expect(try verify([EvidenceRecord(payload: bytes, signature: signer.sign(bytes))])
            == .broken(item: 0, reason: .wrongSeq))
    }

    @Test func theCapturesKindAndClockSourceAreWhatGetsSigned() throws {
        var chain = EvidenceChain(missionId: "kandor-roads")
        try chain.append(Capture(file: Data("invoice".utf8), kind: .scan, capturedAt: Self.start, clockSource: .gnss,
                                 location: nil), signer: signer)

        let signed = try JSONDecoder().decode(EvidencePayload.self, from: chain.records[0].payload)
        #expect((signed.kind, signed.clockSource, signed.location) == (.scan, .gnss, nil))
    }

    @Test func aSlashIsSignedAsItIsNotEscaped() throws {
        // Python writes "/" as is; an escaped "\/" would be different bytes and break the server's check.
        var chain = EvidenceChain(missionId: "kandor/roads")
        try chain.append(Self.capture("photo"), signer: signer)

        let text = String(bytes: chain.records[0].payload, encoding: .utf8) ?? ""
        #expect(text.contains(#""missionId":"kandor/roads""#))
    }

    @Test func aWellFormedItemOfAnotherVersionIsRefused() throws {
        var payload = EvidencePayload(seq: 1, prevHash: EvidenceChain.genesisHash,
                                      contentHash: String(repeating: "a", count: 64), kind: .photo,
                                      capturedAt: "2026-11-12T09:40:00Z", clockSource: .device,
                                      location: nil, missionId: "kandor-roads")
        payload.version = 3
        let bytes = try EvidenceChain.encoder.encode(payload)

        #expect(try verify([EvidenceRecord(payload: bytes, signature: signer.sign(bytes))])
            == .broken(item: 0, reason: .unreadablePayload))
    }

    @Test func anItemThatIsNotVersionTwoIsUnreadable() throws {
        let bytes = Data(#"{"capturedAt":"x","fileSHA256":"ab","missionId":"m","prevHash":"0","seq":1}"#.utf8)

        #expect(try verify([EvidenceRecord(payload: bytes, signature: signer.sign(bytes))])
            == .broken(item: 0, reason: .unreadablePayload))
    }
}
