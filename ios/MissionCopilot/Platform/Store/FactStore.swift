import Foundation
import GRDB

/// The rule (and its version) that produced a fact: the PROV Activity behind it (ADR 0009, 0010).
struct RuleRef: Codable, Sendable, Equatable {
    let id: String
    let version: String
}

/// One piece of evidence a fact was read from, and where on it (a page region, a time range).
struct FactSource: Codable, Sendable, Equatable {
    let seq: Int
    let region: String?
}

struct FactInput: Sendable {
    let name: String
    let value: String
    let unit: String?
    let sources: [FactSource]
    let rule: RuleRef
}

/// A fact as stored: immutable, traceable to its evidence and rule, labelled like its strictest source.
struct Fact: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let value: String
    let unit: String?
    let rule: RuleRef
    let classification: Classification
    let sources: [FactSource]
}

enum FactError: Error, Equatable {
    case noSource
    case unknownSource(seq: Int)
}

/// Facts with their lineage (W3C PROV, ADR 0009): a fact (Entity) wasDerivedFrom its evidence, produced
/// by a rule version (Activity). Its value is sealed with the mission key, so a shred makes it unreadable.
extension MissionStore {
    @discardableResult
    func addFact(_ input: FactInput, to mission: String, now: Date = Date()) throws -> Fact {
        try addFacts([input], to: mission, now: now)[0]
    }

    /// Several facts in one write: all are stored, or none (#138: an invoice's 8 facts go in together).
    @discardableResult
    func addFacts(_ inputs: [FactInput], to mission: String, now: Date = Date()) throws -> [Fact] {
        let key = try missionKey(for: mission)
        let facts = try inputs.map { input in
            guard !input.sources.isEmpty else { throw FactError.noSource }
            return Fact(id: UUID().uuidString.lowercased(), name: input.name, value: input.value, unit: input.unit,
                        rule: input.rule, classification: try strictestLabel(of: input.sources, in: mission),
                        sources: input.sources)
        }
        try store.write { database in
            for fact in facts {
                let sealed = try MissionData.seal(Data(fact.value.utf8), with: key)
                try database.execute(sql: """
                    INSERT INTO fact (id, mission_id, name, sealed_value, unit, rule_id, rule_version,
                                      classification, created_at, first_source_seq)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [fact.id, mission, fact.name, sealed, fact.unit, fact.rule.id, fact.rule.version,
                                     fact.classification.rawValue, now.timeIntervalSince1970, fact.sources[0].seq])
                for source in fact.sources {
                    try database.execute(sql: "INSERT INTO fact_source VALUES (?, ?, ?, ?)",
                                         arguments: [fact.id, mission, source.seq, source.region])
                }
                try EncryptedStore.appendAudit(AuditEntry(action: .factAdded, actor: actor, mission: mission,
                                                          target: fact.id, time: now), in: database)
            }
        }
        return facts
    }

    /// The mission's facts, oldest first (then in the order written), each with its sources in evidence order.
    func facts(in mission: String) throws -> [Fact] {
        let key = try missionKey(for: mission)
        return try store.read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM fact WHERE mission_id = ? ORDER BY created_at, rowid",
                             arguments: [mission]).map { row in
                let sources = try Row.fetchAll(database, sql: """
                    SELECT evidence_seq, region FROM fact_source WHERE fact_id = ? ORDER BY evidence_seq
                    """, arguments: [row["id"] as String]).map { source in
                    FactSource(seq: source["evidence_seq"], region: source["region"])
                }
                guard let value = String(bytes: try MissionData.open(row["sealed_value"], with: key), encoding: .utf8),
                      let label = Classification(rawValue: row["classification"]) else { throw MissionStore.NotText() }
                return Fact(id: row["id"], name: row["name"], value: value, unit: row["unit"],
                            rule: RuleRef(id: row["rule_id"], version: row["rule_version"]), classification: label,
                            sources: sources)
            }
        }
    }

    /// The values as stored, for the proof that the text is not in the row.
    func sealedFactValues(in mission: String) throws -> [Data] {
        try store.read { database in
            try Data.fetchAll(database, sql: "SELECT sealed_value FROM fact WHERE mission_id = ?", arguments: [mission])
        }
    }

    /// NIST FIPS 199 "high water mark": a derived item is as sensitive as its most sensitive input.
    private func strictestLabel(of sources: [FactSource], in mission: String) throws -> Classification {
        let labels = try store.read { database in
            try sources.map { source in
                guard let raw = try String.fetchOne(database, sql: """
                    SELECT classification FROM evidence WHERE mission_id = ? AND seq = ?
                    """, arguments: [mission, source.seq]), let label = Classification(rawValue: raw) else {
                    throw FactError.unknownSource(seq: source.seq)
                }
                return label
            }
        }
        return Classification.strictest(labels)
    }
}
