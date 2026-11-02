import Foundation
import GRDB

struct SentenceInput: Sendable {
    let section: String
    let text: String
    let factIds: [String]
}

/// A report sentence as stored: immutable, built only from facts, labelled like its strictest fact.
struct Sentence: Sendable, Equatable, Identifiable {
    let id: String
    let section: String
    let text: String
    let classification: Classification
    let factIds: [String]
}

/// A sentence followed back to everything behind it (ADR 0009: "any reader can follow a sentence back").
struct Trace: Sendable, Equatable {
    struct Evidence: Sendable, Equatable {
        let seq: Int
        let record: EvidenceRecord
    }

    let sentence: Sentence
    let facts: [Fact]
    let evidence: [Evidence]
}

enum SentenceError: Error, Equatable {
    case noFact
    case unknownFact(id: String)
    case unknownSentence(id: String)
}

extension MissionStore {
    /// A sentence needs at least one fact of this mission; it is as sensitive as its most sensitive fact.
    @discardableResult
    func addSentence(_ input: SentenceInput, to mission: String, now: Date = Date()) throws -> Sentence {
        guard let first = input.factIds.first else { throw SentenceError.noFact }
        let byId = Dictionary(uniqueKeysWithValues: try facts(in: mission).map { ($0.id, $0) })
        let labels = try input.factIds.map { id in
            guard let fact = byId[id] else { throw SentenceError.unknownFact(id: id) }
            return fact.classification
        }
        let sentence = Sentence(id: UUID().uuidString.lowercased(), section: input.section, text: input.text,
                                classification: Classification.strictest(labels), factIds: input.factIds)
        let sealed = try MissionData.seal(Data(input.text.utf8), with: missionKey(for: mission))
        try store.write { database in
            try database.execute(sql: """
                INSERT INTO sentence (id, mission_id, section, sealed_text, classification, created_at, first_fact_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [sentence.id, mission, sentence.section, sealed, sentence.classification.rawValue,
                                 now.timeIntervalSince1970, first])
            for (position, factId) in input.factIds.enumerated() {
                try database.execute(sql: "INSERT INTO sentence_fact VALUES (?, ?, ?, ?)",
                                     arguments: [sentence.id, mission, factId, position])
            }
            try EncryptedStore.appendAudit(AuditEntry(action: .sentenceAdded, actor: actor, mission: mission,
                                                      target: sentence.id, time: now), in: database)
        }
        return sentence
    }

    func sentences(in mission: String) throws -> [Sentence] {
        let key = try missionKey(for: mission)
        return try store.pool.read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM sentence WHERE mission_id = ? ORDER BY created_at, id",
                             arguments: [mission]).map { row in
                let factIds = try String.fetchAll(database, sql: """
                    SELECT fact_id FROM sentence_fact WHERE sentence_id = ? ORDER BY position
                    """, arguments: [row["id"] as String])
                guard let text = String(bytes: try MissionData.open(row["sealed_text"], with: key), encoding: .utf8),
                      let label = Classification(rawValue: row["classification"]) else { throw MissionStore.NotText() }
                return Sentence(id: row["id"], section: row["section"], text: text, classification: label,
                                factIds: factIds)
            }
        }
    }

    /// The sentence, its facts in order, and each piece of evidence behind them once, in chain order.
    func trace(sentence id: String, in mission: String) throws -> Trace {
        guard let sentence = try sentences(in: mission).first(where: { $0.id == id }) else {
            throw SentenceError.unknownSentence(id: id)
        }
        let byId = Dictionary(uniqueKeysWithValues: try facts(in: mission).map { ($0.id, $0) })
        let facts = sentence.factIds.compactMap { byId[$0] }
        let records = try evidence(in: mission)
        let seqs = Set(facts.flatMap { $0.sources.map(\.seq) }).sorted()
        let evidence = seqs.compactMap { seq in
            records.indices.contains(seq - 1) ? Trace.Evidence(seq: seq, record: records[seq - 1]) : nil
        }
        return Trace(sentence: sentence, facts: facts, evidence: evidence)
    }

    /// The texts as stored, for the proof that the words are not in the row.
    func sealedSentenceTexts(in mission: String) throws -> [Data] {
        try store.pool.read { database in
            try Data.fetchAll(database, sql: "SELECT sealed_text FROM sentence WHERE mission_id = ?",
                              arguments: [mission])
        }
    }
}
