import Foundation
import GRDB
import Testing
@testable import MissionCopilot

/// Confirm and store a debrief (#142, step 6.6.8): only once the officer decided every note (confirm, edit or
/// remove) and every heard number (confirm or correct), in one write. A confirmed note or number cites the
/// recording and its place in the transcript (rule debrief v1); an edited or corrected one is the officer's.
/// A note whose quote is not in the transcript cannot be confirmed. The audit names the fact, never its words.
@MainActor
struct DebriefConfirmTests {
    let mission = "kandor-roads"
    static let transcript = DebriefNotesTests.transcript + " Invoice 14 for 480,000 dollars."

    struct Kept {
        let store: MissionStore
        let debrief: Debrief
        let notes: [NoteCheck]
        let numbers: [HeardNumber]
    }

    private func kept(notes: [DebriefNote]? = nil) throws -> Kept {
        let store = try DebriefModelTests.store()
        let debrief = try store.addDebrief(try DebriefStoreTests.recording(), language: .english, to: mission,
                                           signer: SoftwareEvidenceSigner())
        let drafted = try notes ?? DebriefNotesTests.notes
        return Kept(store: store, debrief: debrief,
                    notes: NoteGrounding.check(drafted, transcript: Self.transcript),
                    numbers: SpokenNumbers.find(Self.transcript))
    }

    static func all<D>(_ count: Int, _ decision: D) -> [Int: D] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, decision) })
    }

    @discardableResult
    private func confirm(_ kept: Kept, notes: [Int: NoteDecision], numbers: [Int: NumberDecision],
                         heard: [HeardNumber]? = nil) throws -> [Fact] {
        try kept.store.confirmDebrief(DebriefReview(debrief: kept.debrief, notes: kept.notes,
                                                    numbers: heard ?? kept.numbers),
                                      decisions: DebriefDecisions(notes: notes, numbers: numbers), in: mission)
    }

    private func confirmAll(_ kept: Kept) throws -> [Fact] {
        try confirm(kept, notes: Self.all(kept.notes.count, NoteDecision.confirm),
                    numbers: Self.all(kept.numbers.count, NumberDecision.confirm))
    }

    @Test func confirmedNotesAndNumbersAreStoredWithTheirPlaceInTheRecording() throws {
        let kept = try kept()

        let facts = try confirmAll(kept)

        #expect(try kept.store.facts(in: mission) == facts)
        // Section 3, invoice 14 and invoice 14 again are counts: each one heard is read back.
        #expect(facts.map(\.name) == ["debrief.decision", "debrief.action", "debrief.risk", "spoken.date",
                                      "spoken.time", "spoken.count", "spoken.count", "spoken.count",
                                      "spoken.amount"])
        #expect(facts.allSatisfy { $0.rule == MissionStore.debriefRule })
        #expect(facts.allSatisfy { $0.sources.map(\.seq) == [kept.debrief.seq] })
        let action = try #require(facts.first { $0.name == "debrief.action" })
        #expect(try JSONDecoder().decode(NoteValue.self, from: Data(action.value.utf8))
                == NoteValue(text: "Contractor shows a new work plan.", who: "the contractor", byWhen: "in two weeks"))
        let span = try #require(kept.notes[1].found)
        #expect(action.sources.first?.region == "\(DebriefTranscript.engine) text \(span.offset)+\(span.length)")
        let amount = try #require(facts.last)
        #expect(amount.value == "480000")
        #expect(amount.unit == "dollars")
    }

    @Test func editsAndCorrectionsAreTheOfficersAndARemovedNoteIsNotStored() throws {
        let kept = try kept()
        var notes = Self.all(kept.notes.count, NoteDecision.confirm)
        notes[0] = .edit("Deadline extended to March 15, only with a new work plan.")
        notes[2] = .remove
        var numbers = Self.all(kept.numbers.count, NumberDecision.confirm)
        numbers[kept.numbers.count - 1] = .correct("48000")

        let facts = try self.confirm(kept, notes: notes, numbers: numbers)

        #expect(facts.map(\.name).filter { $0.hasPrefix("debrief.") } == ["debrief.decision", "debrief.action"])
        #expect(facts[0].rule == MissionStore.officerRule)
        #expect(facts[0].value.contains("only with a new work plan"))
        #expect(facts.last?.value == "48000")
        #expect(facts.last?.rule == MissionStore.officerRule)
    }

    @Test func nothingIsStoredUntilEverythingIsDecided() throws {
        let kept = try kept()
        var notes = Self.all(kept.notes.count, NoteDecision.confirm)
        notes[1] = nil
        var numbers = Self.all(kept.numbers.count, NumberDecision.confirm)
        numbers[0] = nil

        #expect(throws: MissionStore.DebriefNotDecided(notes: [1], numbers: [0])) {
            try self.confirm(kept, notes: notes, numbers: numbers)
        }
        #expect(try kept.store.facts(in: mission).isEmpty)
    }

    @Test func aNoteNotSaidCannotBeConfirmedOnlyEditedOrRemoved() throws {
        let made = DebriefNote(kind: .decision, text: "The minister approved the invoice.", who: "", byWhen: "",
                               quote: "the minister approved the invoice")
        let kept = try kept(notes: [made])
        let numbers = Self.all(kept.numbers.count, NumberDecision.confirm)

        #expect(throws: MissionStore.CannotConfirmNote(index: 0)) {
            try self.confirm(kept, notes: [0: .confirm], numbers: numbers)
        }
        let edited = try self.confirm(kept, notes: [0: .edit("Ask who approves invoice 14.")], numbers: numbers)
        #expect(edited.first?.sources == [FactSource(seq: kept.debrief.seq, region: nil)])
    }

    @Test func anEmptyEditOrCorrectionIsRefused() throws {
        let kept = try kept()
        var notes = Self.all(kept.notes.count, NoteDecision.confirm)
        notes[0] = .edit("  ")
        var numbers = Self.all(kept.numbers.count, NumberDecision.confirm)

        #expect(throws: MissionStore.CannotConfirmNote(index: 0)) {
            try self.confirm(kept, notes: notes, numbers: numbers)
        }
        notes[0] = .confirm
        numbers[0] = .correct(" ")
        #expect(throws: MissionStore.CannotConfirmNumber(index: 0)) {
            try self.confirm(kept, notes: notes, numbers: numbers)
        }
    }

    @Test func aDebriefIsConfirmedOnceAndTheAuditHasNoWords() throws {
        let kept = try kept()
        let facts = try confirmAll(kept)

        #expect(throws: MissionStore.AlreadyConfirmed.self) { try self.confirmAll(kept) }
        #expect(try kept.store.confirmedDebriefs(in: mission) == [kept.debrief.seq])
        let added = try kept.store.store.auditEvents().filter { $0.action == .factAdded }
        #expect(added.map(\.target) == facts.map(\.id))
        #expect(!added.contains { ($0.target ?? "").contains("work plan") })
    }

    @Test func removingEverythingSavesNothing() throws {
        let kept = try kept(notes: [DebriefNote(kind: .risk, text: "r", who: "", byWhen: "", quote: "")])
        let bare = Kept(store: kept.store, debrief: kept.debrief, notes: kept.notes, numbers: [])

        #expect(throws: MissionStore.NothingToSave.self) {
            try self.confirm(bare, notes: [0: .remove], numbers: [:], heard: [])
        }
    }
}
