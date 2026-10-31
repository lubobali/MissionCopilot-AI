import CryptoKit
import Foundation

/// The signed head: "this mission's chain has `count` items and ends at `headHash`".
/// A chain alone cannot see its last item cut off; the head can.
struct HeadPayload: Codable, Equatable {
    let count: Int
    let headHash: String
    let missionId: String
}

extension EvidenceChain {
    /// Signed again after every append, stored next to the chain.
    public func signedHead(signer: any EvidenceSigner) throws -> EvidenceRecord {
        let payload = HeadPayload(count: records.count, headHash: records.last.map(Self.link) ?? Self.genesisHash,
                                  missionId: missionId)
        let bytes = try Self.encoder.encode(payload)
        return EvidenceRecord(payload: bytes, signature: try signer.sign(bytes))
    }

    /// Chain check plus head check. Known limit: an older head with a chain cut back to it still verifies;
    /// only an outside record of the latest head (the server's sync receipt, ADR 0006) catches that.
    public static func verify(_ records: [EvidenceRecord], head: EvidenceRecord, publicKeyDER: Data) -> Verification {
        guard let publicKey = try? P256.Signing.PublicKey(derRepresentation: publicKeyDER),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: head.signature),
              publicKey.isValidSignature(signature, for: head.payload) else {
            return .brokenHead(.badSignature)
        }
        guard let claimed = try? JSONDecoder().decode(HeadPayload.self, from: head.payload) else {
            return .brokenHead(.unreadable)
        }
        let chainResult = verify(records, publicKeyDER: publicKeyDER)
        guard chainResult == .valid(count: records.count) else { return chainResult }
        let missions = records.compactMap { try? JSONDecoder().decode(EvidencePayload.self, from: $0.payload).missionId }
        guard missions.allSatisfy({ $0 == claimed.missionId }) else { return .brokenHead(.wrongMission) }
        guard claimed.count == records.count else { return .brokenHead(.countMismatch) }
        guard claimed.headHash == (records.last.map(link) ?? genesisHash) else { return .brokenHead(.hashMismatch) }
        return chainResult
    }
}
