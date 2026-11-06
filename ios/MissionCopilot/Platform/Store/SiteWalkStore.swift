import Foundation
import GRDB

/// What the officer saw of an agreed action on site (#129).
enum ActionSeen: String, CaseIterable, Sendable {
    case done, inProgress, notStarted, couldNotCheck
}

/// One agreed action's check: what was seen, an optional note (sealed in the store) and an optional photo
/// (the seq of its evidence in the mission's chain).
struct ActionCheck: Equatable, Sendable {
    let seen: ActionSeen
    let note: String?
    var photo: Int?
}

/// A finished site walk: the form's version and when it was finished.
struct FinishedWalk: Equatable, Sendable {
    let version: String
    let finishedAt: Date
}

/// The site walk's records (#129, schema v11): checklist answers and agreed-action checks, sealed with the
/// mission key so a shred makes them unreadable, and changeable until the walk is finished. After that the
/// app refuses with `WalkFinished`, and the database refuses too (triggers), so no code path skips it. The
/// audit log names the question, the action's key or the form, never a value or a note.
extension MissionStore {
    struct WalkFinished: Error, Equatable { let mission: String }
    struct NoSuchPhoto: Error, Equatable { let seq: Int }

    /// Saves an answer, replacing the question's last one; an empty answer clears it.
    func saveAnswer(_ value: String, to question: String, form: String, mission: String,
                    now: Date = Date()) throws {
        try refuseIfFinished(form: form, mission: mission)
        let sealed = value.isEmpty ? nil : try MissionData.seal(Data(value.utf8), with: missionKey(for: mission))
        try store.write { database in
            if let sealed {
                try database.execute(sql: """
                    INSERT INTO site_answer VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (mission_id, form_id, question)
                    DO UPDATE SET sealed_value = excluded.sealed_value, answered_at = excluded.answered_at
                    """, arguments: [mission, form, question, sealed, now.timeIntervalSince1970])
            } else {
                try database.execute(sql: """
                    DELETE FROM site_answer WHERE mission_id = ? AND form_id = ? AND question = ?
                    """, arguments: [mission, form, question])
            }
            try EncryptedStore.appendAudit(AuditEntry(action: .siteAnswered, actor: actor, mission: mission,
                                                      target: question, time: now), in: database)
        }
    }

    func answers(form: String, mission: String) throws -> [String: String] {
        let key = try missionKey(for: mission)
        let rows = try store.read { database in
            try Row.fetchAll(database, sql: """
                SELECT question, sealed_value FROM site_answer WHERE mission_id = ? AND form_id = ?
                """, arguments: [mission, form])
        }
        var answers: [String: String] = [:]
        for row in rows {
            let value = try MissionData.open(row["sealed_value"], with: key)
            answers[row["question"]] = String(bytes: value, encoding: .utf8)
        }
        return answers
    }

    /// Saves what was seen of an agreed action (keyed by the SHA-256 of its text), replacing the last check.
    func saveCheck(_ seen: ActionSeen, note: String?, photo: Int? = nil, action: String, mission: String,
                   now: Date = Date()) throws {
        if try isAnyWalkFinished(mission: mission) { throw WalkFinished(mission: mission) }
        if let photo, try !hasEvidence(photo, in: mission) { throw NoSuchPhoto(seq: photo) }
        let key = try missionKey(for: mission)
        let sealed = try note.flatMap { $0.isEmpty ? nil : try MissionData.seal(Data($0.utf8), with: key) }
        try store.write { database in
            try database.execute(sql: """
                INSERT INTO action_check (mission_id, action_key, seen, sealed_note, checked_at, photo_seq)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (mission_id, action_key)
                DO UPDATE SET seen = excluded.seen, sealed_note = excluded.sealed_note,
                    checked_at = excluded.checked_at, photo_seq = excluded.photo_seq
                """, arguments: [mission, action, seen.rawValue, sealed, now.timeIntervalSince1970, photo])
            try EncryptedStore.appendAudit(AuditEntry(action: .actionChecked, actor: actor, mission: mission,
                                                      target: action, time: now), in: database)
        }
    }

    func checks(mission: String) throws -> [String: ActionCheck] {
        let key = try missionKey(for: mission)
        let rows = try store.read { database in
            try Row.fetchAll(database, sql: """
                SELECT action_key, seen, sealed_note, photo_seq FROM action_check WHERE mission_id = ?
                """, arguments: [mission])
        }
        var checks: [String: ActionCheck] = [:]
        for row in rows {
            guard let seen = ActionSeen(rawValue: row["seen"]) else { continue }
            let note = try (row["sealed_note"] as Data?).map { String(bytes: try MissionData.open($0, with: key),
                                                                       encoding: .utf8) } ?? nil
            checks[row["action_key"]] = ActionCheck(seen: seen, note: note, photo: row["photo_seq"])
        }
        return checks
    }

    /// Finishes the walk: from now on its answers and the mission's action checks cannot change.
    func finishWalk(form: String, version: String, mission: String, now: Date = Date()) throws {
        try refuseIfFinished(form: form, mission: mission)
        try store.write { database in
            try database.execute(sql: "INSERT INTO site_walk_finished VALUES (?, ?, ?, ?)",
                                 arguments: [mission, form, version, now.timeIntervalSince1970])
            try EncryptedStore.appendAudit(AuditEntry(action: .siteWalkFinished, actor: actor, mission: mission,
                                                      target: "\(form) \(version)", time: now), in: database)
        }
    }

    func finishedWalk(form: String, mission: String) throws -> FinishedWalk? {
        try store.read { database in
            try Row.fetchOne(database, sql: """
                SELECT form_version, finished_at FROM site_walk_finished WHERE mission_id = ? AND form_id = ?
                """, arguments: [mission, form])
                .map { row in
                    FinishedWalk(version: row["form_version"],
                                 finishedAt: Date(timeIntervalSince1970: row["finished_at"]))
                }
        }
    }

    private func refuseIfFinished(form: String, mission: String) throws {
        if try finishedWalk(form: form, mission: mission) != nil { throw WalkFinished(mission: mission) }
    }

    private func hasEvidence(_ seq: Int, in mission: String) throws -> Bool {
        try store.read { database in
            try Bool.fetchOne(database, sql: "SELECT EXISTS (SELECT 1 FROM evidence WHERE mission_id = ? AND seq = ?)",
                              arguments: [mission, seq]) ?? false
        }
    }

    private func isAnyWalkFinished(mission: String) throws -> Bool {
        try store.read { database in
            try Bool.fetchOne(database, sql: "SELECT EXISTS (SELECT 1 FROM site_walk_finished WHERE mission_id = ?)",
                              arguments: [mission]) ?? false
        }
    }
}
