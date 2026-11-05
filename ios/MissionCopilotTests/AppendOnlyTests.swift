import Foundation
import Testing
@testable import MissionCopilot

/// Records that cannot be changed (domain invariant 5, #72): evidence, facts and sentences are never
/// updated, and never deleted one by one; only removing a whole mission (purge, after its shred) takes
/// them away. Shred records can never be changed or deleted. Database rules, proven with raw SQL.
/// These stop bugs; the tamper evidence for a stolen database is the Secure Enclave signatures.
struct AppendOnlyTests {
    private let signer = SoftwareEvidenceSigner()

    /// A mission with one of everything: evidence, a fact, a sentence, and a shredded second mission.
    private func store() throws -> MissionStore {
        let (store, facts) = try SentenceStoreTests.mission()
        try store.addSentence(SentenceInput(section: "Findings", text: "Paid ahead of progress.",
                                            factIds: [facts[0].id]), to: "kandor-roads")
        try store.create(mission: "old", title: "old")
        _ = try store.shredAll(reason: .officer, at: Date(), policy: FieldPolicy())
        try store.create(mission: "kandor-roads-2", title: "second")
        // A record from before mission lives (#94): the old table is no longer written, but stays protected.
        try store.store.rawExecuteForTests("INSERT INTO shred_record VALUES ('old', 'officer', 1000)")
        return store
    }

    private func refused(_ store: MissionStore, _ sql: String) -> Bool {
        do {
            try store.store.rawExecuteForTests(sql)
            return false
        } catch {
            return "\(error)".contains("append-only")
        }
    }

    @Test(arguments: [
        "UPDATE evidence SET signature = x'00'",
        "UPDATE fact SET name = 'changed'",
        "UPDATE fact_source SET region = 'elsewhere'",
        "UPDATE sentence SET section = 'changed'",
        "UPDATE sentence_fact SET position = 9",
        "UPDATE shred_record SET reason = 'officer'",
        "UPDATE shred_event SET reason = 'officer'"
    ])
    func noRecordCanBeChanged(sql: String) throws {
        #expect(refused(try store(), sql))
    }

    @Test(arguments: ["evidence", "fact", "fact_source", "sentence", "sentence_fact", "shred_record",
                     "shred_event"])
    func noRecordCanBeDeletedOnItsOwn(table: String) throws {
        #expect(refused(try store(), "DELETE FROM \(table)"))
    }

    @Test func removingAWholeShreddedMissionStillTakesEverythingAway() throws {
        let (store, facts) = try SentenceStoreTests.mission()
        try store.addSentence(SentenceInput(section: "Findings", text: "x", factIds: [facts[0].id]), to: "kandor-roads")
        _ = try store.shredAll(reason: .officer, at: Date(), policy: FieldPolicy())

        try store.purge(mission: "kandor-roads")

        #expect(try store.sealedEvidence(in: "kandor-roads").isEmpty)
        #expect(try store.sealedFactValues(in: "kandor-roads").isEmpty)
        #expect(try store.sealedSentenceTexts(in: "kandor-roads").isEmpty)
        #expect(try store.shredRecords().map(\.mission) == ["kandor-roads"])  // the record of the shred stays
    }

    @Test func theChainHeadIsStillReplacedAfterEveryItem() throws {
        let (store, _) = try SentenceStoreTests.mission()

        try store.addEvidence(EvidenceChainTests.capture("third", minute: 9), to: "kandor-roads", signer: signer)

        let head = try #require(try store.evidenceHead(in: "kandor-roads"))
        #expect(try JSONDecoder().decode(HeadPayload.self, from: head.payload).count == 3)
    }
}
