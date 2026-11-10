import Foundation
import GRDB

/// A stored approval (#163): which draft, who, when, the exact bytes signed, the signature and the key that
/// checks it (the server checks it in Phase 8, as it checks evidence).
struct ReportApprovalRecord: Sendable, Equatable {
    let draftId: String
    let approvedBy: String
    let approvedAt: Date
    let payload: Data
    let signature: Data
    let publicKeyDER: Data
}

/// The approval record (#163, step 7.3.3; threat T13): only the latest saved draft, only when the signed bytes
/// are exactly that draft's, by that person, at that time; once per mission, append-only, with an audit entry.
/// After it no draft can be saved over the report.
extension MissionStore {
    struct NotTheLatestDraft: Error, Equatable {}
    struct NotWhatWasSigned: Error, Equatable {}
    struct ReportApproved: Error, Equatable {}

    @discardableResult
    func approve(_ signed: SignedApproval, draft: ReportDraft, by user: String, at time: Date,
                 in mission: String) throws -> ReportApprovalRecord {
        if try approval(in: mission) != nil { throw ReportApproved() }
        guard try latestDraft(in: mission)?.id == draft.id else { throw NotTheLatestDraft() }
        guard try ReportApproval.payload(draft: draft, mission: mission, by: user, at: time) == signed.payload else {
            throw NotWhatWasSigned()
        }
        let record = ReportApprovalRecord(draftId: draft.id, approvedBy: user,
                                          approvedAt: Date(timeIntervalSince1970: time.timeIntervalSince1970
                                                               .rounded()),
                                          payload: signed.payload, signature: signed.signature,
                                          publicKeyDER: signed.publicKeyDER)
        try store.write { database in
            try database.execute(sql: "INSERT INTO report_approval VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [
                record.draftId, mission, record.approvedBy, record.approvedAt.timeIntervalSince1970, record.payload,
                record.signature, record.publicKeyDER
            ])
            try EncryptedStore.appendAudit(AuditEntry(action: .reportApproved, actor: actor, mission: mission,
                                                      target: record.draftId, time: time), in: database)
        }
        return record
    }

    func approval(in mission: String) throws -> ReportApprovalRecord? {
        try store.read { database in
            try Row.fetchOne(database, sql: "SELECT * FROM report_approval WHERE mission_id = ?",
                             arguments: [mission]).map { row in
                ReportApprovalRecord(draftId: row["draft_id"], approvedBy: row["approved_by"],
                                     approvedAt: Date(timeIntervalSince1970: row["approved_at"]),
                                     payload: row["payload"], signature: row["signature"],
                                     publicKeyDER: row["public_key"])
            }
        }
    }
}
