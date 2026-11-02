import CryptoKit
import Foundation

/// Hash-chained evidence for one mission (ADR 0009): each item signs the link of the item before it,
/// so changing, removing, swapping or renumbering any item is detected offline with the public key.
struct EvidenceChain: Sendable {
    enum BreakReason: Equatable, Sendable { case badSignature, unreadablePayload, wrongSeq, wrongPrevHash }
    enum HeadProblem: Equatable, Sendable { case badSignature, unreadable, countMismatch, hashMismatch, wrongMission }

    enum Verification: Equatable, Sendable {
        case valid(count: Int)
        case broken(item: Int, reason: BreakReason)
        case brokenHead(HeadProblem)
    }

    static let genesisHash = String(repeating: "0", count: 64)

    let missionId: String
    private(set) var records: [EvidenceRecord] = []

    init(missionId: String) {
        self.missionId = missionId
    }

    mutating func append(_ capture: Capture, signer: any EvidenceSigner) throws {
        let payload = EvidencePayload(
            seq: records.count + 1, prevHash: records.last.map(Self.link) ?? Self.genesisHash,
            contentHash: Self.hex(SHA256.hash(data: capture.file)), kind: capture.kind,
            capturedAt: Self.timestamp(capture.capturedAt), clockSource: capture.clockSource,
            location: capture.location, missionId: missionId)
        let bytes = try Self.encoder.encode(payload)
        records.append(EvidenceRecord(payload: bytes, signature: try signer.sign(bytes)))
    }

    /// Takes back a record already signed (a chain reloaded from the store); verify() checks it.
    mutating func adopt(_ record: EvidenceRecord) {
        records.append(record)
    }

    /// Offline check with only the public key: signatures, version 2, sequence numbers and links, in order.
    static func verify(_ records: [EvidenceRecord], publicKeyDER: Data) -> Verification {
        guard let publicKey = try? P256.Signing.PublicKey(derRepresentation: publicKeyDER) else {
            return .broken(item: 0, reason: .badSignature)
        }
        var expectedPrev = genesisHash
        for (index, record) in records.enumerated() {
            guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: record.signature),
                  publicKey.isValidSignature(signature, for: record.payload) else {
                return .broken(item: index, reason: .badSignature)
            }
            guard let payload = try? JSONDecoder().decode(EvidencePayload.self, from: record.payload),
                  payload.version == 2 else { return .broken(item: index, reason: .unreadablePayload) }
            guard payload.prevHash == expectedPrev else { return .broken(item: index, reason: .wrongPrevHash) }
            guard payload.seq == index + 1 else { return .broken(item: index, reason: .wrongSeq) }
            expectedPrev = link(record)
        }
        return .valid(count: records.count)
    }

    /// The next item's prevHash: SHA-256 over the signed bytes followed by the signature.
    static func link(_ record: EvidenceRecord) -> String {
        hex(SHA256.hash(data: record.payload + record.signature))
    }

    /// Sorted keys, no spaces, slashes not escaped: the canonical bytes of docs/evidence-format.md.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// UTC, whole seconds (the second it was captured in): "2026-11-12T09:41:07Z".
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
