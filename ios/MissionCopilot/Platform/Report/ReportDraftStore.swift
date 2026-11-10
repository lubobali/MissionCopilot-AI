import Foundation
import GRDB

/// A stored report draft: its sentences in order, its language, when (#161).
struct ReportDraft: Sendable, Equatable, Identifiable {
    let id: String
    let language: String
    let createdAt: Date
    let sentences: [Sentence]
}

/// Report drafts (#161, step 7.2.2): the draft's sentences and their order in one write; never changed, a new
/// draft for each save. A line with no proof is never stored (ADR 0009: an untraceable sentence cannot exist).
extension MissionStore {
    struct NoProof: Error, Equatable { let text: String }

    @discardableResult
    func saveDraft(_ lines: [ReportLine], language: AnswerLanguage, in mission: String,
                   now: Date = Date()) throws -> ReportDraft {
        if try approval(in: mission) != nil { throw ReportApproved() }  // #163: never drafted over
        if let unproven = lines.first(where: { $0.factIds.isEmpty || !$0.checked }) {
            throw NoProof(text: unproven.text)
        }
        let prepared = try prepare(lines.map {
            SentenceInput(section: $0.section.rawValue, text: $0.text, factIds: $0.factIds)
        }, in: mission)
        let draft = ReportDraft(id: UUID().uuidString.lowercased(), language: language == .french ? "fr" : "en",
                                createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded()),
                                sentences: prepared.map(\.sentence))
        try store.write { database in
            try database.execute(sql: "INSERT INTO report_draft VALUES (?, ?, ?, ?)",
                                 arguments: [draft.id, mission, draft.language, draft.createdAt.timeIntervalSince1970])
            for (position, item) in prepared.enumerated() {
                try insert(item, mission: mission, now: now, in: database)
                try database.execute(sql: "INSERT INTO report_line VALUES (?, ?, ?, ?)",
                                     arguments: [draft.id, mission, position, item.sentence.id])
            }
            try EncryptedStore.appendAudit(AuditEntry(action: .reportDrafted, actor: actor, mission: mission,
                                                      target: "\(draft.id) \(prepared.count) sentences", time: now),
                                           in: database)
        }
        return draft
    }

    /// The mission's drafts, oldest first.
    func drafts(in mission: String) throws -> [ReportDraft] {
        let sentences = Dictionary(uniqueKeysWithValues: try self.sentences(in: mission).map { ($0.id, $0) })
        let rows = try store.read { database in
            try Row.fetchAll(database, sql: """
                SELECT d.id, d.language, d.created_at, l.sentence_id FROM report_draft d
                LEFT JOIN report_line l ON l.draft_id = d.id
                WHERE d.mission_id = ? ORDER BY d.created_at, d.rowid, l.position
                """, arguments: [mission])
        }
        var drafts: [ReportDraft] = []
        for row in rows {
            let id: String = row["id"]
            let sentence = (row["sentence_id"] as String?).flatMap { sentences[$0] }
            if let last = drafts.last, last.id == id {
                drafts[drafts.count - 1] = ReportDraft(id: id, language: last.language, createdAt: last.createdAt,
                                                       sentences: last.sentences + [sentence].compactMap { $0 })
            } else {
                drafts.append(ReportDraft(id: id, language: row["language"],
                                          createdAt: Date(timeIntervalSince1970: row["created_at"]),
                                          sentences: [sentence].compactMap { $0 }))
            }
        }
        return drafts
    }

    func latestDraft(in mission: String) throws -> ReportDraft? { try drafts(in: mission).last }
}
