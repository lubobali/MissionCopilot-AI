import Foundation
import Testing
@testable import MissionCopilot

/// The notes review's model (#142, step 6.6.9; #152): for one transcribed debrief, code writes the notes from
/// the sentences said and finds every heard number (checked against the pack), no model; the officer confirms,
/// edits, relabels or removes each note, tags a sentence code left, confirms or corrects each number, then saves.
@MainActor
struct DebriefReviewModelTests {
    let mission = "kandor-roads"
    static let transcript = DebriefConfirmTests.transcript

    private func model() async throws -> (DebriefReviewModel, MissionStore) {
        let store = try DebriefModelTests.store()
        let debrief = try store.addDebrief(try DebriefStoreTests.recording(), language: .english, to: mission,
                                           signer: SoftwareEvidenceSigner())
        _ = try await store.transcribe(debrief, in: mission,
                                       engine: DebriefTranscriptTests.FakeTranscriber(.success(Self.transcript)))
        let model = DebriefReviewModel(mission: mission, debrief: debrief, store: store,
                                       contracts: try InvoiceBankViewTests.kandor().contracts)
        return (model, store)
    }

    @Test func theNotesAndNumbersAreDraftedAndChecked() async throws {
        let (model, _) = try await model()

        await model.draft()

        // The transcript's sentences: "They agreed ..." is a decision, "... need to check invoice 14" an action;
        // the other three carry no cue word and wait to be tagged. No model is asked.
        #expect(model.stage == .review)
        #expect(model.notes.map(\.kind) == ["Decision", "Action"])
        #expect(model.notes[0].text.hasPrefix("They agreed to extend the contractor deadline to March 15"))
        #expect(model.notes[0].detail == "Who: the contractor · By when: March 15")
        #expect(model.notes.allSatisfy { $0.fromSentence && $0.canConfirm && $0.problems.isEmpty })
        #expect(model.untagged.map(\.text) == [
            "Just met the deputy minister of transport and the road agency director.",
            "Section 3 bridge still not started.", "Invoice 14 for 480,000 dollars."
        ])
        #expect(model.numbers.map(\.heard) == ["March 15", "two weeks", "3", "14", "14", "480,000 dollars"])
        #expect(model.summary == "2 notes · 6 numbers · 0 of 8 decided")
    }

    @Test func aWrongNumberShowsItsProblem() async throws {
        let (model, _) = try await model()
        await model.draft()

        // The transcript says invoice 14 for 480,000: right. A planted 48,000 would be a problem (6.6.7);
        // here the context shows the words around each number.
        #expect(model.numbers.last?.context == "14. Invoice 14 for 480,000 dollars")
        let clear = model.numbers.allSatisfy { (line: DebriefReviewModel.NumberLine) -> Bool in line.problems.isEmpty }
        #expect(clear)
    }

    @Test func theOfficerDecidesEverythingThenSaves() async throws {
        let (model, store) = try await model()
        await model.draft()

        model.tag(1, as: .risk)  // "Section 3 bridge still not started."
        #expect(model.notes.last?.text == "Section 3 bridge still not started.")
        model.decide(note: 0, .confirm)
        model.decide(note: 1, .edit("Check invoice 14."))
        model.decide(note: 2, .remove)
        for index in model.numbers.indices.dropLast() { model.decide(number: index, .confirm) }
        #expect(!model.canSave)
        #expect(model.correct(number: model.numbers.count - 1, to: "480000"))
        #expect(model.canSave)
        #expect(model.notes[2].decision == "Removed")
        #expect(model.numbers.last?.decision == "Corrected to 480000")
        model.save()

        #expect(model.stage == .saved(count: 8))
        #expect(try store.facts(in: mission).count == 8)
        #expect(try store.confirmedDebriefs(in: mission).count == 1)
    }

    /// Found on the iPhone: a number the pack disagrees with was confirmed past its warning. The pack's value
    /// is offered in one tap, and keeping the heard one is said plainly.
    @Test func aNumberThePackDisagreesWithOffersThePacksValue() async throws {
        let (model, store) = try await model()
        await model.draft()
        let misheard = SpokenNumbers.check(SpokenNumbers.find("Invoice 14 for $180,000."),
                                           contracts: try InvoiceBankViewTests.kandor().contracts)
        let line = DebriefReviewModel.line(misheard[1], index: 0, decision: nil)

        #expect(line.suggestion == "480000")
        #expect(line.suggestionWords == "Use 480,000 (from the pack)")
        #expect(model.numbers.allSatisfy { $0.suggestion == nil })
        _ = store
    }

    /// The officer changes a sentence note's label; it stays the same words, to decide again.
    @Test func aSentenceNotesLabelCanBeChanged() async throws {
        let (model, _) = try await model()
        await model.draft()
        model.decide(note: 1, .confirm)

        model.relabel(note: 1, as: .risk)

        #expect(model.notes[1].kind == "Risk")
        #expect(model.notes[1].text.hasSuffix("need to check invoice 14."))
        #expect(model.notes[1].decision == nil)
        model.tag(9, as: .action)  // not a sentence: nothing happens
        #expect(model.untagged.count == 3)
    }

    /// The officer still writes a note of their own; it is theirs, and its label is not a sentence's.
    @Test func theOfficerCanStillWriteANote() async throws {
        let (model, store) = try await model()
        await model.draft()

        model.addNote(.action, "Send the no-objection by Friday.")
        #expect(model.notes.last?.decision == "Written by you")
        #expect(model.notes.last?.fromSentence == false)
        model.relabel(note: 2, as: .risk)
        #expect(model.notes.last?.kind == "Action")
        model.decide(note: 0, .remove)
        model.decide(note: 1, .remove)
        for index in model.numbers.indices { model.decide(number: index, .confirm) }
        model.save()

        #expect(model.stage == .saved(count: 7))
        #expect(try store.facts(in: mission).first?.rule == MissionStore.officerRule)
    }

    @Test func aSavedDebriefIsNotDraftedAgain() async throws {
        let (model, store) = try await model()
        await model.draft()
        model.decide(note: 0, .confirm)
        model.decide(note: 1, .confirm)
        for index in model.numbers.indices { model.decide(number: index, .confirm) }
        model.save()
        #expect(model.stage == .saved(count: 8))

        let again = DebriefReviewModel(mission: mission, debrief: model.debrief, store: store, contracts: nil)
        await again.draft()

        #expect(again.stage == .alreadySaved)
    }
}
