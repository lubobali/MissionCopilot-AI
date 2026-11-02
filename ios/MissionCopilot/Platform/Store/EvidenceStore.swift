import CryptoKit
import Foundation
import GRDB

/// Evidence in the store (ADR 0008 and 0009). Each signed record and its file are sealed with the
/// mission's key before they touch the database, so a shred makes both unreadable at once. The head
/// (a count and a hash) and the signatures are stored as they are: they reveal nothing about the mission.
extension MissionStore {
    struct SealedEvidence: Equatable {
        let payload: Data
        let file: Data
    }

    struct NoEvidence: Error, Equatable { let mission: String }

    /// Signs the capture into the mission's chain, re-signs the head, and stores both, sealed.
    @discardableResult
    func addEvidence(_ capture: Capture, to mission: String, signer: any EvidenceSigner) throws -> EvidenceRecord {
        let key = try missionKey(for: mission)
        var chain = EvidenceChain(missionId: mission)
        for record in try evidence(in: mission) { chain.adopt(record) }
        try chain.append(capture, signer: signer)
        guard let record = chain.records.last else { throw NoEvidence(mission: mission) }
        let head = try chain.signedHead(signer: signer)
        let sealedPayload = try MissionData.seal(record.payload, with: key)
        let sealedFile = try MissionData.seal(capture.file, with: key)
        try store.write { database in
            try database.execute(sql: "INSERT INTO evidence VALUES (?, ?, ?, ?, ?)", arguments: [
                mission, chain.records.count, sealedPayload, record.signature, sealedFile
            ])
            try database.execute(sql: "INSERT OR REPLACE INTO evidence_head VALUES (?, ?, ?)",
                                 arguments: [mission, head.payload, head.signature])
        }
        return record
    }

    /// The mission's signed records, in order: the exact bytes that were signed.
    func evidence(in mission: String) throws -> [EvidenceRecord] {
        let key = try missionKey(for: mission)
        let rows = try store.pool.read { database in
            try Row.fetchAll(database, sql: """
                SELECT sealed_payload, signature FROM evidence WHERE mission_id = ? ORDER BY seq
                """, arguments: [mission])
        }
        return try rows.map { row in
            EvidenceRecord(payload: try MissionData.open(row["sealed_payload"], with: key), signature: row["signature"])
        }
    }

    func evidenceHead(in mission: String) throws -> EvidenceRecord? {
        try store.pool.read { database in
            try Row.fetchOne(database, sql: "SELECT payload, signature FROM evidence_head WHERE mission_id = ?",
                             arguments: [mission])
        }.map { EvidenceRecord(payload: $0["payload"], signature: $0["signature"]) }
    }

    func evidenceFile(in mission: String, seq: Int) throws -> Data {
        let key = try missionKey(for: mission)
        let sealed = try store.pool.read { database in
            try Data.fetchOne(database, sql: "SELECT sealed_file FROM evidence WHERE mission_id = ? AND seq = ?",
                              arguments: [mission, seq])
        }
        guard let sealed else { throw NoEvidence(mission: mission) }
        return try MissionData.open(sealed, with: key)
    }

    /// The rows as stored, for the proof that nothing readable is in them.
    func sealedEvidence(in mission: String) throws -> [SealedEvidence] {
        try store.pool.read { database in
            try Row.fetchAll(database, sql: """
                SELECT sealed_payload, sealed_file FROM evidence WHERE mission_id = ? ORDER BY seq
                """, arguments: [mission])
        }.map { SealedEvidence(payload: $0["sealed_payload"], file: $0["sealed_file"]) }
    }

    /// The chain as the phone exports it for sync and for the Python verifier: base64 fields.
    func exportEvidence(of mission: String, signer: any EvidenceSigner) throws -> Data {
        struct Export: Encodable {
            let publicKeyDER: Data
            let records: [EvidenceRecord]
            let head: EvidenceRecord
        }
        guard let head = try evidenceHead(in: mission) else { throw NoEvidence(mission: mission) }
        let export = Export(publicKeyDER: try signer.publicKeyDER(), records: try evidence(in: mission), head: head)
        return try JSONEncoder().encode(export)
    }
}
