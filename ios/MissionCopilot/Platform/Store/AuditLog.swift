import CryptoKit
import Foundation
import GRDB

/// One event of the phone's audit log: who did what to which mission, and when. Never any content.
struct AuditEvent: Sendable, Equatable {
    enum Action: String, Codable, Sendable {
        case missionCreated, evidenceAdded, factAdded, sentenceAdded, leaseRenewed, missionShredded, missionPurged
        case packImported  // #92: the target is the version ("v3"), never any content
        // #129: the target is the question's name, the action's key, or the form and its version; never a value
        case siteAnswered, actionChecked, siteWalkFinished
        case redFlagRaised  // #134: the target is the rule id ("MC-01"), never a value or an input
        case documentScanned  // #138: the target is the scan's id and its page count, never its text
        case pageRead  // #138: the target is the page's evidence seq and the reader, never what it read
        case debriefTranscribed  // #142: the target is the debrief's evidence seq and the engine, never words
        case debriefRecorded  // #142: the target is the audio's evidence seq, length and language, never words
        case questionAsked  // #145: the target is the kept entry's id, never the question or the answer
        case reportDrafted  // #161: the target is the draft's id and its sentence count, never its words
        case reportApproved  // #163: the target is the approved draft's id, never its words
    }

    let seq: Int
    let time: Int
    let actor: String
    let action: Action
    let mission: String?
    let target: String?
    let prevHash: String
    let hash: String
}

/// What one change records before it is chained: the action and who did it to which mission.
struct AuditEntry: Sendable {
    let action: AuditEvent.Action
    let actor: String
    let mission: String?
    let target: String?
    let time: Date
}

/// The result of checking the whole chain.
enum AuditVerification: Equatable {
    enum Reason: Equatable { case changed, wrongPrevHash, unreadable }
    case valid(count: Int)
    case broken(seq: Int, reason: Reason)
}

/// The hashed fields of an event, encoded like evidence (sorted keys, integers only).
private struct AuditPayload: Encodable {
    let action: AuditEvent.Action
    let actor: String
    let at: Int  // swiftlint:disable:this identifier_name
    let missionId: String?
    let prevHash: String
    let seq: Int
    let targetId: String?
}

/// The hash chain over all events (domain invariant 6). Appended in the same transaction as each change.
extension EncryptedStore {
    static func appendAudit(_ entry: AuditEntry, in database: Database) throws {
        let last = try Row.fetchOne(database, sql: "SELECT seq, hash FROM audit_event ORDER BY seq DESC LIMIT 1")
        let seq = (last?["seq"] as Int? ?? 0) + 1
        let prev = last?["hash"] as String? ?? EvidenceChain.genesisHash
        let seconds = Int(entry.time.timeIntervalSince1970)
        let hash = try hashOf(AuditPayload(action: entry.action, actor: entry.actor, at: seconds,
                                           missionId: entry.mission, prevHash: prev, seq: seq, targetId: entry.target))
        try database.execute(sql: "INSERT INTO audit_event VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
            seq, seconds, entry.actor, entry.action.rawValue, entry.mission, entry.target, prev, hash
        ])
    }

    func auditEvents() throws -> [AuditEvent] {
        try read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM audit_event ORDER BY seq").compactMap { row in
                guard let action = AuditEvent.Action(rawValue: row["action"]) else { return nil }
                return AuditEvent(seq: row["seq"], time: row["at"], actor: row["actor"], action: action,
                                  mission: row["mission_id"], target: row["target_id"], prevHash: row["prev_hash"],
                                  hash: row["hash"])
            }
        }
    }

    /// Recomputes every hash and link in order: a changed, removed or renumbered event breaks the chain.
    /// The number is inside each hash and any gap breaks the next link, so no separate number check.
    func verifyAudit() throws -> AuditVerification {
        let rows = try read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM audit_event ORDER BY seq")
        }
        var prev = EvidenceChain.genesisHash
        for row in rows {
            let seq: Int = row["seq"]
            guard let action = AuditEvent.Action(rawValue: row["action"]) else {
                return .broken(seq: seq, reason: .unreadable)
            }
            let payload = AuditPayload(action: action, actor: row["actor"], at: row["at"],
                                       missionId: row["mission_id"], prevHash: row["prev_hash"], seq: seq,
                                       targetId: row["target_id"])
            guard try Self.hashOf(payload) == row["hash"] as String else { return .broken(seq: seq, reason: .changed) }
            guard row["prev_hash"] as String == prev else { return .broken(seq: seq, reason: .wrongPrevHash) }
            prev = row["hash"]
        }
        return .valid(count: rows.count)
    }

    private static func hashOf(_ payload: AuditPayload) throws -> String {
        EvidenceChain.hex(SHA256.hash(data: try EvidenceChain.encoder.encode(payload)))
    }
}
