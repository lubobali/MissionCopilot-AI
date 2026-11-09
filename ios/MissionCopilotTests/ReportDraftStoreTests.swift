import Foundation
import GRDB
import Testing
@testable import MissionCopilot

/// Report drafts (#161, step 7.2.2): a draft is its sentences in order, stored in one write (v20); each sentence
/// cites its facts (v6); drafts are never changed, drafting again makes a new one; a line with no proof is never
/// stored.
@MainActor
struct ReportDraftStoreTests {
    static let mission = PackDownloaderTests.mission

    static func drafted() async throws -> (MissionStore, [ReportLine]) {
        let (store, flags) = try await ReportSourcesTests.finished()
        let facts = try ReportSourcesTests.write(store, flags)
        let words = RedFlagWords(rules: RedFlagEngineTests.rules)
        let lines = flags.map { WordedLine(key: $0.rule.id, title: words.title($0), text: words.sentence($0)) }
        let sources = MissionSources.build(SourceInputs(packFiles: try store.packFiles(in: mission), flags: lines))
        return (store, ReportWriter.write(sources: sources, facts: facts,
                                          flagged: ReportWriterTests.flaggedNames(flags), language: .english))
    }

    @Test func aDraftIsItsSentencesInOrder() async throws {
        let (store, lines) = try await Self.drafted()

        let draft = try store.saveDraft(lines, language: .english, in: Self.mission)
        let read = try #require(try store.latestDraft(in: Self.mission))

        #expect(read == draft)
        #expect(read.language == "en")
        #expect(read.sentences.map(\.text) == lines.map(\.text))
        #expect(read.sentences.map(\.section) == lines.map(\.section.rawValue))
        #expect(read.sentences.map(\.factIds) == lines.map(\.factIds))
        #expect(try store.sentences(in: Self.mission).count == lines.count)
        let trace = try store.trace(sentence: read.sentences[0].id, in: Self.mission)
        #expect(!trace.evidence.isEmpty)
    }

    /// Drafting again makes a new draft; the first one stays as it was.
    @Test func eachSaveIsANewDraft() async throws {
        let (store, lines) = try await Self.drafted()

        let first = try store.saveDraft(lines, language: .english, in: Self.mission)
        let second = try store.saveDraft(Array(lines.dropFirst()), language: .english, in: Self.mission)

        #expect(first.id != second.id)
        #expect(try store.latestDraft(in: Self.mission) == second)
        #expect(try store.drafts(in: Self.mission).map(\.id) == [first.id, second.id])
        #expect(try store.drafts(in: Self.mission).first == first)
    }

    /// A line with no proof (no fact, or one that failed its check) stops the whole save: nothing is stored.
    @Test func aLineWithNoProofIsNeverStored() async throws {
        let (store, lines) = try await Self.drafted()
        let unproven = ReportLine(section: .findings, text: "The road is in good condition.", factIds: [],
                                  checked: false, reason: "It cites no fact.")

        #expect(throws: MissionStore.NoProof(text: unproven.text)) {
            try store.saveDraft(lines + [unproven], language: .english, in: Self.mission)
        }
        #expect(try store.sentences(in: Self.mission).isEmpty)
        #expect(try store.latestDraft(in: Self.mission) == nil)
    }

    /// The database refuses to change or remove a draft's lines while the mission lives.
    @Test func aDraftCannotBeChanged() async throws {
        let (store, lines) = try await Self.drafted()
        let draft = try store.saveDraft(lines, language: .english, in: Self.mission)

        for sql in ["UPDATE report_line SET position = 99", "DELETE FROM report_line",
                    "UPDATE report_draft SET language = 'fr'", "DELETE FROM report_draft"] {
            #expect(throws: (any Error).self, "\(sql)") { try store.store.write { try $0.execute(sql: sql) } }
        }
        #expect(try store.latestDraft(in: Self.mission) == draft)
    }

    /// The audit names the draft and its size, never its words.
    @Test func theAuditNamesTheDraftNeverItsWords() async throws {
        let (store, lines) = try await Self.drafted()

        let draft = try store.saveDraft(lines, language: .english, in: Self.mission)

        let events = try store.store.auditEvents()
        #expect(events.contains { $0.action == .reportDrafted && $0.target == "\(draft.id) \(lines.count) sentences" })
        #expect(!events.contains { $0.target?.contains("Red flag") == true })
    }
}
