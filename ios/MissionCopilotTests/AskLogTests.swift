import Foundation
import GRDB
import Testing
@testable import MissionCopilot

/// Questions and answers kept (#145, step 6.7.7, decided B): sealed with the mission key (schema v18),
/// append-only, gone only with the mission; the sources found are copied as they were, so the record explains
/// itself after a newer pack. The audit names the entry's id, never the words. A kept answer is never a fact.
@MainActor
struct AskLogTests {
    let mission = "kandor-roads"
    static let walkDay = SiteWalkTests.walkDay

    private func store() throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        return store
    }

    static func answered() throws -> AskResult {
        let source = try #require(MissionAnswerTests.sources.first { $0.id == MissionAnswerTests.invoice14 })
        return AskResult(question: "When was invoice 14 paid?", found: [source],
                         sentences: [AnswerSentence(text: "Invoice 14 was paid on 12 October 2026.",
                                                    sources: [source.id])],
                         leftOut: [LeftOutSentence(text: "It was USD 48,000.", sources: [source.id],
                                                   reason: "The number 48000 is not in the sources it cites.")])
    }

    @Test func aCheckedAnswerIsKeptWithItsSourcesAsTheyWere() throws {
        let store = try store()
        let result = try Self.answered()

        let kept = try store.keepAnswer(result, in: mission, now: Self.walkDay)

        #expect(try store.askHistory(in: mission) == [kept])
        #expect(kept.question == "When was invoice 14 paid?")
        #expect(kept.language == "en")
        #expect(kept.askedAt == Self.walkDay)
        #expect(kept.sentences == result.sentences)
        #expect(kept.leftOut == result.leftOut)
        #expect(kept.why == nil && kept.answered)
        // The source as it was: its words and the pack file's hash, whatever pack comes later.
        #expect(kept.found == result.found)
        guard case .pack(let citation) = kept.found.first?.origin else {
            Issue.record("not a pack source")
            return
        }
        #expect(!citation.sha256.isEmpty)
        #expect(kept.found.first?.text.contains("reference: Invoice 14") == true)
    }

    @Test func notAnsweredIsKeptWithWhyAndTheSourcesFound() throws {
        let store = try store()
        let result = try Self.answered()

        let kept = try store.keepAnswer(AskResult(question: "Quand la facture 14 a-t-elle été payée ?",
                                                  found: result.found, why: .noneBacked), in: mission)

        #expect(!kept.answered)
        #expect(kept.why == .noneBacked)
        #expect(kept.language == "fr")
        #expect(kept.found.count == 1)
    }

    @Test func historyIsNewestFirst() throws {
        let store = try store()
        let base = try Self.answered()
        for (index, question) in ["First?", "Second?", "Third?"].enumerated() {
            try store.keepAnswer(AskResult(question: question, found: base.found, why: .dataDoesNotSay), in: mission,
                                 now: Self.walkDay.addingTimeInterval(Double(index) * 60))
        }

        #expect(try store.askHistory(in: mission).map(\.question) == ["Third?", "Second?", "First?"])
        #expect(try store.askHistory(in: "another").isEmpty)
    }

    @Test func theWordsAreSealed() throws {
        let store = try store()

        try store.keepAnswer(try Self.answered(), in: mission)

        let sealed = try store.store.read { try Data.fetchAll($0, sql: "SELECT sealed_entry FROM ask_entry") }
        #expect(sealed.count == 1)
        #expect(!sealed[0].contains(Data("invoice 14".utf8)) && !sealed[0].contains(Data("Invoice 14".utf8)))
    }

    @Test(arguments: ["UPDATE ask_entry SET asked_at = 0", "DELETE FROM ask_entry"])
    func theDatabaseKeepsTheAnswerAsItWas(sql: String) throws {
        let store = try store()
        try store.keepAnswer(try Self.answered(), in: mission)

        #expect(throws: DatabaseError.self) { try store.store.rawExecuteForTests(sql) }
    }

    /// Crypto-shred: once the mission's key is destroyed the kept answers cannot be read; the purge then
    /// removes their rows (ADR 0008 rule 7, key first).
    @Test func keptAnswersGoWithTheirMission() throws {
        let store = try store()
        try store.keepAnswer(try Self.answered(), in: mission)

        _ = try store.shredAll(reason: .shredOrder, at: Self.walkDay, policy: FieldPolicy())

        #expect(throws: (any Error).self) { try store.askHistory(in: self.mission) }
        try store.purge(mission: mission)
        #expect(try store.store.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ask_entry") } == 0)
    }

    @Test func theAuditNamesTheEntryNeverTheWords() throws {
        let store = try store()

        let kept = try store.keepAnswer(try Self.answered(), in: mission)

        let events = try store.store.auditEvents().filter { $0.action == .questionAsked }
        #expect(events.map(\.target) == [kept.id])
        #expect(events.allSatisfy { !($0.target ?? "").contains("invoice") })
        #expect(try store.store.verifyAudit() == .valid(count: try store.store.auditEvents().count))
    }

    /// A kept answer is never a fact: the sources a later question searches are the same before and after.
    @Test func aKeptAnswerIsNeverASource() throws {
        let store = try store()
        let before = MissionSources.load(mission: mission, store: store)

        try store.keepAnswer(try Self.answered(), in: mission)

        let after = MissionSources.load(mission: mission, store: store)
        #expect(after.map(\.id) == before.map(\.id))
        #expect(try store.facts(in: mission).isEmpty)
    }
}
