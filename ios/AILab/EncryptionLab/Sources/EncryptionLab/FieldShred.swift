import Foundation
import GRDB

/// What the organization allows on its phones (ADR 0012).
public struct FieldPolicy: Equatable, Sendable {
    public struct OfficerShredTurnedOff: Error, Equatable {}

    /// The officer's own "Destroy this mission" button. A shred order works either way.
    public let officerMayShred: Bool

    public init(officerMayShred: Bool = true) {
        self.officerMayShred = officerMayShred
    }
}

/// One crypto-shred, kept to report on the next sync: which mission, why and when. Never its content.
public struct ShredRecord: Equatable, Sendable {
    public enum Reason: String, Sendable { case leaseEnded, clockMovedBack, officer, shredOrder }
    public struct UnknownReason: Error {}

    public let mission: String
    public let reason: Reason
    public let at: Date
}

extension MissionStore {
    /// Shreds every mission whose lease ended. A mission with no lease is shredded too: fail safe.
    public func enforce(leases: [KeyLease], now: Date, lastSeen: Date) throws -> [ShredRecord] {
        let byMission = Dictionary(leases.map { ($0.mission, $0) }, uniquingKeysWith: { $1 })
        var shredded: [ShredRecord] = []
        for mission in try liveMissionIDs() {
            let reason: ShredRecord.Reason? = switch byMission[mission]?.state(now: now, lastSeen: lastSeen) {
            case .valid: nil
            case .ended(.clockMovedBack): .clockMovedBack
            case .ended(.expired), nil: .leaseEnded
            }
            if let reason { shredded.append(try shred(mission, reason: reason, at: now)) }
        }
        return shredded
    }

    /// Shreds every mission still readable: for a shred order, or the officer's button if allowed.
    public func shredAll(reason: ShredRecord.Reason, at now: Date, policy: FieldPolicy) throws -> [ShredRecord] {
        if reason == .officer, !policy.officerMayShred { throw FieldPolicy.OfficerShredTurnedOff() }
        return try liveMissionIDs().map { try shred($0, reason: reason, at: now) }
    }

    public func shredRecords() throws -> [ShredRecord] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT mission_id, reason, at FROM shred_record ORDER BY mission_id").map {
                guard let reason = ShredRecord.Reason(rawValue: $0["reason"]) else { throw ShredRecord.UnknownReason() }
                return ShredRecord(mission: $0["mission_id"], reason: reason, at: Date(timeIntervalSince1970: $0["at"]))
            }
        }
    }

    private func liveMissionIDs() throws -> [String] {
        let done = Set(try shredRecords().map(\.mission))
        return try missionIDs().filter { !done.contains($0) }
    }

    /// Key first, then the record: a crash in between leaves an unreadable mission, never a readable one.
    private func shred(_ mission: String, reason: ShredRecord.Reason, at now: Date) throws -> ShredRecord {
        try shred(mission: mission)
        try db.write { db in
            try db.execute(sql: "INSERT INTO shred_record VALUES (?, ?, ?)",
                           arguments: [mission, reason.rawValue, now.timeIntervalSince1970])
        }
        return ShredRecord(mission: mission, reason: reason, at: now)
    }
}
