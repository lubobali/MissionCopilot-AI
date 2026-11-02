import Foundation
import Testing
@testable import MissionCopilot

/// The phone's audit log (domain invariant 6, #72): every change to a mission is recorded in the same
/// transaction, hash-chained, never with content, and kept even after the mission is purged. Changing or
/// removing an event is caught by the chain, even by someone who first removes the append-only rule.
struct AuditLogTests {
    private func busyStore() throws -> MissionStore {
        let (store, facts) = try SentenceStoreTests.mission()
        try store.addSentence(SentenceInput(section: "Findings", text: "Paid ahead of progress.",
                                            factIds: [facts[0].id]), to: "kandor-roads")
        try store.renewLease(for: "kandor-roads", at: Date())
        _ = try store.shredAll(reason: .officer, at: Date(), policy: FieldPolicy())
        try store.purge(mission: "kandor-roads")
        return store
    }

    @Test func everyChangeIsRecordedInOrder() throws {
        let actions = try busyStore().store.auditEvents().map(\.action)

        #expect(actions == [.missionCreated, .evidenceAdded, .factAdded, .evidenceAdded, .factAdded, .sentenceAdded,
                            .leaseRenewed, .missionShredded, .missionPurged])
    }

    @Test func theLogVerifiesAndOutlivesThePurgedMission() throws {
        let store = try busyStore()

        #expect(try store.store.verifyAudit() == .valid(count: 9))
        #expect(try store.store.auditEvents().allSatisfy { $0.mission == "kandor-roads" })
    }

    @Test func eventsCarryNoContent() throws {
        let events = try busyStore().store.auditEvents()
        let text = events.map { "\($0.action) \($0.target ?? "")" }.joined(separator: " ")

        #expect(!text.contains("Paid ahead") && !text.contains("Kandor rural roads"))
        #expect(events.allSatisfy { $0.actor == "phone" && $0.hash.count == 64 })
    }

    @Test func aChangedEventIsCaughtEvenWithoutTheAppendOnlyRule() throws {
        let store = try busyStore()
        try store.store.rawExecuteForTests("DROP TRIGGER audit_event_no_update")

        try store.store.rawExecuteForTests("UPDATE audit_event SET action = 'missionCreated' WHERE seq = 8")

        #expect(try store.store.verifyAudit() == .broken(seq: 8, reason: .changed))
    }

    @Test func aRemovedEventIsCaughtEvenWithoutTheAppendOnlyRule() throws {
        let store = try busyStore()
        try store.store.rawExecuteForTests("DROP TRIGGER audit_event_no_delete")

        try store.store.rawExecuteForTests("DELETE FROM audit_event WHERE seq = 8")

        #expect(try store.store.verifyAudit() == .broken(seq: 9, reason: .wrongPrevHash))
    }

    @Test func aRemovedEventWithTheNextOneRelinkedIsStillCaught() throws {
        // A careful attacker hides the gap by pointing event 9 at event 7; the link is inside 9's hash.
        let store = try busyStore()
        try store.store.rawExecuteForTests("DROP TRIGGER audit_event_no_update")
        try store.store.rawExecuteForTests("DROP TRIGGER audit_event_no_delete")

        try store.store.rawExecuteForTests("""
            UPDATE audit_event SET prev_hash = (SELECT hash FROM audit_event WHERE seq = 7) WHERE seq = 9;
            DELETE FROM audit_event WHERE seq = 8;
            """)

        #expect(try store.store.verifyAudit() == .broken(seq: 9, reason: .changed))
    }

    @Test(arguments: ["UPDATE audit_event SET actor = 'someone'", "DELETE FROM audit_event"])
    func theAppendOnlyRuleRefusesChanges(sql: String) throws {
        let store = try busyStore()

        #expect(throws: (any Error).self) { try store.store.rawExecuteForTests(sql) }
        #expect(try store.store.verifyAudit() == .valid(count: 9))
    }
}
