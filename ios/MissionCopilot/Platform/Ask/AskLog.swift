import Foundation
import GRDB
import NaturalLanguage

/// A kept question and its checked answer (#145, step 6.7.7, decided B): the question, its language, the
/// time, the sentences shown with the ids of the sources they cite, the sentences left out and why, or why
/// there is no answer, and every source found copied as it was at that moment (title, words, and where it
/// came from, a pack field with its file's hash), so the record still explains itself after a newer pack.
/// A kept answer is never a fact: no red flag, note, report or later answer reads it.
struct AskRecord: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let question: String
    /// "en" or "fr" as the phone recognized it offline; "und" when it could not tell.
    let language: String
    let askedAt: Date
    let found: [MissionSource]
    let sentences: [AnswerSentence]
    let leftOut: [LeftOutSentence]
    let why: AskResult.Why?
    /// Written by code or chosen by the model; nil in answers kept before 6.7.15.
    var madeBy: AnswerMaker?

    var answered: Bool { !sentences.isEmpty }

    init(_ result: AskResult, id: String = UUID().uuidString, language: String, askedAt: Date) {
        (self.id, self.question, self.language, self.askedAt) = (id, result.question, language, askedAt)
        (found, sentences, leftOut, why) = (result.found, result.sentences, result.leftOut, result.why)
        madeBy = result.madeBy
    }

    /// The question's language, recognized on the phone (English or French), or "und".
    static func language(of question: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .french]
        recognizer.processString(question)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let (language, confidence) = hypotheses.first, confidence >= 0.5 else { return "und" }
        return language.rawValue
    }
}

extension StoreSchema {
    static func registerAskLog(in migrator: inout DatabaseMigrator) {
        // Questions and answers kept (#145, decided B): sealed with the mission key, append-only, gone only
        // with their mission (crypto-shred). Only the id and the time are in the clear.
        migrator.registerMigration("v18-ask-answers") { database in
            try database.execute(sql: """
                CREATE TABLE ask_entry (
                    id TEXT PRIMARY KEY,
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    sealed_entry BLOB NOT NULL,
                    asked_at REAL NOT NULL);
                CREATE TRIGGER ask_entry_no_update BEFORE UPDATE ON ask_entry
                BEGIN SELECT RAISE(ABORT, 'append-only: a kept answer cannot be changed'); END;
                CREATE TRIGGER ask_entry_no_delete BEFORE DELETE ON ask_entry
                WHEN EXISTS (SELECT 1 FROM mission WHERE id = OLD.mission_id)
                BEGIN SELECT RAISE(ABORT, 'append-only: a kept answer goes only with its mission'); END;
                """)
        }
    }
}

extension MissionStore {
    /// The question and its checked answer, sealed with the mission key; the audit names the entry's id,
    /// never the question's words.
    @discardableResult
    func keepAnswer(_ result: AskResult, in mission: String, now: Date = Date()) throws -> AskRecord {
        // The time as the store keeps it (seconds since 1970), so a record read back is equal to this one.
        let record = AskRecord(result, language: AskRecord.language(of: result.question),
                               askedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970))
        let sealed = try MissionData.seal(try JSONEncoder().encode(record), with: missionKey(for: mission))
        try store.write { database in
            try database.execute(sql: "INSERT INTO ask_entry VALUES (?, ?, ?, ?)",
                                 arguments: [record.id, mission, sealed, now.timeIntervalSince1970])
            try EncryptedStore.appendAudit(AuditEntry(action: .questionAsked, actor: actor, mission: mission,
                                                      target: record.id, time: now), in: database)
        }
        return record
    }

    /// The mission's kept questions and answers, newest first.
    func askHistory(in mission: String) throws -> [AskRecord] {
        let sealed = try store.read { database in
            try Data.fetchAll(database, sql: """
                SELECT sealed_entry FROM ask_entry WHERE mission_id = ? ORDER BY asked_at DESC, rowid DESC
                """, arguments: [mission])
        }
        guard !sealed.isEmpty else { return [] }
        let key = try missionKey(for: mission)
        return try sealed.map { try JSONDecoder().decode(AskRecord.self, from: try MissionData.open($0, with: key)) }
    }
}
