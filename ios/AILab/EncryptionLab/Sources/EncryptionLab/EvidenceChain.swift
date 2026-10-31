import CryptoKit
import Foundation

/// One signed evidence item: the exact bytes that were signed, and the DER signature over them.
/// Verifiers check these bytes as stored and never re-encode the JSON, so Swift and Python agree.
public struct EvidenceRecord: Codable, Sendable, Equatable {
    public let payload: Data
    public let signature: Data

    public init(payload: Data, signature: Data) {
        self.payload = payload
        self.signature = signature
    }
}

/// What gets signed for each photo, scan or recording (ADR 0009). Sorted keys, ISO 8601 UTC, integers only.
struct EvidencePayload: Codable, Equatable {
    let seq: Int
    let prevHash: String
    let fileSHA256: String
    let capturedAt: String
    let missionId: String
}

/// Hash-chained evidence for one mission: each item signs the hash of the item before it.
public struct EvidenceChain: Sendable {
    public enum BreakReason: Equatable, Sendable {
        case badSignature, unreadablePayload, wrongSeq, wrongPrevHash
    }

    public enum HeadProblem: Equatable, Sendable {
        case badSignature, unreadable, countMismatch, hashMismatch, wrongMission
    }

    public enum Verification: Equatable, Sendable {
        case valid(count: Int)
        case broken(at: Int, reason: BreakReason)
        case brokenHead(HeadProblem)
    }

    static let genesisHash = String(repeating: "0", count: 64)

    public let missionId: String
    public private(set) var records: [EvidenceRecord] = []

    public init(missionId: String) {
        self.missionId = missionId
    }

    public mutating func append(file: Data, capturedAt: Date, signer: any EvidenceSigner) throws {
        let payload = EvidencePayload(
            seq: records.count + 1,
            prevHash: records.last.map(Self.link) ?? Self.genesisHash,
            fileSHA256: Self.hex(SHA256.hash(data: file)),
            capturedAt: Self.timestamp(capturedAt),
            missionId: missionId)
        let bytes = try Self.encoder.encode(payload)
        records.append(EvidenceRecord(payload: bytes, signature: try signer.sign(bytes)))
    }

    /// Offline check with only the public key: signatures, sequence numbers and links, in order.
    public static func verify(_ records: [EvidenceRecord], publicKeyDER: Data) -> Verification {
        guard let publicKey = try? P256.Signing.PublicKey(derRepresentation: publicKeyDER) else {
            return .broken(at: 0, reason: .badSignature)
        }
        var expectedPrev = genesisHash
        for (index, record) in records.enumerated() {
            guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: record.signature),
                  publicKey.isValidSignature(signature, for: record.payload) else {
                return .broken(at: index, reason: .badSignature)
            }
            guard let payload = try? JSONDecoder().decode(EvidencePayload.self, from: record.payload) else {
                return .broken(at: index, reason: .unreadablePayload)
            }
            guard payload.prevHash == expectedPrev else { return .broken(at: index, reason: .wrongPrevHash) }
            guard payload.seq == index + 1 else { return .broken(at: index, reason: .wrongSeq) }
            expectedPrev = link(record)
        }
        return .valid(count: records.count)
    }

    /// The next item's prevHash: SHA-256 over the signed bytes followed by the signature.
    static func link(_ record: EvidenceRecord) -> String {
        hex(SHA256.hash(data: record.payload + record.signature))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false)
            .timeSeparator(.colon).timeZone(separator: .omitted))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
