import CryptoKit
import Foundation
import GRDB

/// One stored input: a pack field or a signed photo.
private struct StoredFlagInput: Codable {
    var pack: PackCitation?
    var evidence: PhotoRef?
}

/// The red flags stored at the finish (#134): one row per result in the engine's order. The rule and the
/// outcome stay readable for counting; everything else (subject, numbers, inputs) is sealed.
extension MissionStore {
    private struct Detail: Codable {
        let subject: String?
        let computed: Double?
        let threshold: RedFlagRule.Threshold
        let reason: RedFlagResult.NotChecked?
        let inputs: [StoredFlagInput]
        let skippedMissions: Int
    }

    /// Writes the flags inside the caller's transaction (the finish), sealed with the mission key.
    func insert(_ flags: [RedFlagResult], mission: String, key: SymmetricKey, now: Date,
                in database: Database) throws {
        for (position, flag) in flags.enumerated() {
            let (outcome, reason): (String, RedFlagResult.NotChecked?) = switch flag.outcome {
            case .flag: ("flag", nil)
            case .clear: ("clear", nil)
            case .notChecked(let why): ("notChecked", why)
            }
            let inputs = flag.inputs.map { input -> StoredFlagInput in
                switch input {
                case .pack(let citation): StoredFlagInput(pack: citation)
                case .evidence(let photo): StoredFlagInput(evidence: photo)
                }
            }
            let detail = Detail(subject: flag.subject, computed: flag.computed, threshold: flag.threshold,
                                reason: reason, inputs: inputs, skippedMissions: flag.skippedMissions)
            let sealed = try MissionData.seal(try JSONEncoder().encode(detail), with: key)
            try database.execute(sql: "INSERT INTO red_flag VALUES (?, ?, ?, ?, ?, ?, 'strictly_confidential', ?)",
                                 arguments: [mission, position, flag.rule.id, flag.rule.version, outcome, sealed,
                                             now.timeIntervalSince1970])
            if flag.outcome == .flag {
                try EncryptedStore.appendAudit(AuditEntry(action: .redFlagRaised, actor: actor, mission: mission,
                                                          target: flag.rule.id, time: now), in: database)
            }
        }
    }

    /// The flags stored at the finish, or nil while the walk is not finished.
    func storedFlags(mission: String) throws -> [RedFlagResult]? {
        let (finished, rows) = try store.read { database in
            (try Bool.fetchOne(database, sql: "SELECT EXISTS (SELECT 1 FROM site_walk_finished WHERE mission_id = ?)",
                               arguments: [mission]) ?? false,
             try Row.fetchAll(database, sql: "SELECT * FROM red_flag WHERE mission_id = ? ORDER BY position",
                              arguments: [mission]))
        }
        guard finished else { return nil }
        let key = try missionKey(for: mission)
        return try rows.map { row in
            let opened = try MissionData.open(row["sealed_detail"], with: key)
            let detail = try JSONDecoder().decode(Detail.self, from: opened)
            let outcome: RedFlagResult.Outcome = switch row["outcome"] as String {
            case "flag": .flag
            case "clear": .clear
            default: .notChecked(detail.reason ?? .unknownRule)
            }
            let inputs = detail.inputs.compactMap { input -> RedFlagResult.Input? in
                if let citation = input.pack { return .pack(citation) }
                return input.evidence.map(RedFlagResult.Input.evidence)
            }
            var result = RedFlagResult(rule: RuleRef(id: row["rule_id"], version: row["rule_version"]),
                                       outcome: outcome, subject: detail.subject, computed: detail.computed,
                                       threshold: detail.threshold, inputs: inputs)
            result.skippedMissions = detail.skippedMissions
            return result
        }
    }
}
