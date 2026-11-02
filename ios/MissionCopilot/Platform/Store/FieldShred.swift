import Foundation
import GRDB

/// What the organization allows on its phones (ADR 0012).
struct FieldPolicy: Equatable, Sendable {
    struct OfficerShredTurnedOff: Error, Equatable {}

    /// The officer's own "Destroy this mission" button. A shred order works either way.
    var officerMayShred = true
}

/// One crypto-shred, kept to report on the next sync: which mission, why and when. Never its content.
struct ShredRecord: Equatable, Sendable {
    enum Reason: String, Sendable { case leaseEnded, clockMovedBack, officer, shredOrder }
    struct UnknownReason: Error {}

    let mission: String
    let reason: Reason
    let time: Date
}

/// ADR 0012 in the store: each mission's lease is kept with it, checked on launch and unlock.
extension MissionStore {
    func lease(for mission: String) throws -> KeyLease? {
        try store.pool.read { database in
            try Row.fetchOne(database, sql: "SELECT renewed_at, days FROM mission_lease WHERE mission_id = ?",
                             arguments: [mission])
        }.map { KeyLease(mission: mission, renewedAt: Date(timeIntervalSince1970: $0["renewed_at"]), days: $0["days"]) }
    }

    /// A confirmed sync renews the lease from that moment.
    func renewLease(for mission: String, at sync: Date) throws {
        try store.write { database in
            try database.execute(sql: "UPDATE mission_lease SET renewed_at = ? WHERE mission_id = ?",
                                 arguments: [sync.timeIntervalSince1970, mission])
        }
    }

    /// Removes a lease, so the next check shreds the mission (fail safe).
    func dropLease(for mission: String) throws {
        try store.write { database in
            try database.execute(sql: "DELETE FROM mission_lease WHERE mission_id = ?", arguments: [mission])
        }
    }

    /// The latest time the app has seen; a clock set back from it ends every lease.
    func lastSeen() throws -> Date? {
        try store.info("last_seen").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    /// Shreds every mission whose lease ended or is missing, then moves the last-seen time forward.
    func enforce(now: Date) throws -> [ShredRecord] {
        let seen = try lastSeen() ?? now
        var shredded: [ShredRecord] = []
        for mission in try liveMissionIDs() {
            let reason: ShredRecord.Reason? = switch try lease(for: mission)?.state(now: now, lastSeen: seen) {
            case .valid: nil
            case .ended(.clockMovedBack): .clockMovedBack
            case .ended(.expired), nil: .leaseEnded
            }
            if let reason { shredded.append(try shred(mission, reason: reason, at: now)) }
        }
        try store.setInfo("last_seen", String(KeyLease.lastSeen(previous: seen, now: now).timeIntervalSince1970))
        return shredded
    }

    /// Shreds every mission still readable: for a shred order, or the officer's button if allowed.
    func shredAll(reason: ShredRecord.Reason, at now: Date, policy: FieldPolicy) throws -> [ShredRecord] {
        if reason == .officer, !policy.officerMayShred { throw FieldPolicy.OfficerShredTurnedOff() }
        return try liveMissionIDs().map { try shred($0, reason: reason, at: now) }
    }

    func shredRecords() throws -> [ShredRecord] {
        try store.pool.read { database in
            try Row.fetchAll(database, sql: "SELECT mission_id, reason, at FROM shred_record ORDER BY mission_id")
        }.map { row in
            guard let reason = ShredRecord.Reason(rawValue: row["reason"]) else { throw ShredRecord.UnknownReason() }
            return ShredRecord(mission: row["mission_id"], reason: reason, time: Date(timeIntervalSince1970: row["at"]))
        }
    }

    private func liveMissionIDs() throws -> [String] {
        let done = Set(try shredRecords().map(\.mission))
        return try missionIDs().filter { !done.contains($0) }
    }

    /// Key first, then the record: a crash in between leaves an unreadable mission, never a readable one.
    private func shred(_ mission: String, reason: ShredRecord.Reason, at now: Date) throws -> ShredRecord {
        try shred(mission: mission)
        try store.write { database in
            try database.execute(sql: "INSERT INTO shred_record VALUES (?, ?, ?)",
                                 arguments: [mission, reason.rawValue, now.timeIntervalSince1970])
        }
        return ShredRecord(mission: mission, reason: reason, time: now)
    }
}
