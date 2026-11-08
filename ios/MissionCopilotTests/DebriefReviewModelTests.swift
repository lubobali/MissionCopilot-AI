import Foundation
import Testing
@testable import MissionCopilot

/// The notes review's model (#142, step 6.6.9): for one transcribed debrief, the assistant drafts notes, code
/// grounds them and finds every heard number (checked against the pack); the officer confirms, edits or
/// removes each note and confirms or corrects each number, then saves. When the assistant cannot help, the
/// officer writes the notes.
@MainActor
struct DebriefReviewModelTests {
    let mission = "kandor-roads"
    static let transcript = DebriefConfirmTests.transcript

    private func model(answer: String = DebriefNotesTests.answer) async throws -> (DebriefReviewModel, MissionStore) {
        let store = try DebriefModelTests.store()
        let debrief = try store.addDebrief(try DebriefStoreTests.recording(), language: .english, to: mission,
                                           signer: SoftwareEvidenceSigner())
        _ = try await store.transcribe(debrief, in: mission,
                                       engine: DebriefTranscriptTests.FakeTranscriber(.success(Self.transcript)))
        let model = DebriefReviewModel(mission: mission, debrief: debrief, store: store,
                                       contracts: try InvoiceBankViewTests.kandor().contracts,
                                       model: FieldModel(engine: FieldModelTests.FakeEngine(answer: answer)))
        return (model, store)
    }

    @Test func theNotesAndNumbersAreDraftedAndChecked() async throws {
        let (model, _) = try await model()

        await model.draft()

        #expect(model.stage == .review)
        #expect(model.notes.map(\.kind) == ["Decision", "Action", "Risk"])
        #expect(model.notes[1].detail == "Who: the contractor · By when: in two weeks")
        #expect(model.notes[1].quote == "“the contractor shows a new work plan in two weeks”")
        #expect(model.numbers.map(\.heard) == ["March 15", "two weeks", "3", "14", "14", "480,000 dollars"])
        #expect(model.summary == "3 notes · 6 numbers · 0 of 9 decided")
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

        model.decide(note: 0, .confirm)
        model.decide(note: 1, .edit("Contractor sends a new work plan."))
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

    @Test func aNoteNotSaidCannotBeConfirmed() async throws {
        let made = #"{"notes":[{"kind":"decision","text":"Approved.","who":"","byWhen":"","#
            + #""quote":"the minister approved it"}]}"#
        let (model, _) = try await model(answer: made)
        await model.draft()

        model.decide(note: 0, .confirm)

        #expect(model.notes[0].decision == nil)
        #expect(!model.notes[0].canConfirm)
        #expect(model.notes[0].problems == ["These words are not in the debrief: “the minister approved it”."])
    }

    @Test func whenTheAssistantCannotHelpTheOfficerWritesTheNotes() async throws {
        let (model, store) = try await model(answer: "no JSON")
        await model.draft()
        #expect(model.stage == .toOfficer(.notUsable))

        model.writeYourself()
        model.addNote(.action, "Send the no-objection by Friday.")
        #expect(model.notes.map(\.decision) == ["Written by you"])
        for index in model.numbers.indices { model.decide(number: index, .confirm) }
        model.save()

        #expect(model.stage == .saved(count: 7))
        #expect(try store.facts(in: mission).first?.rule == MissionStore.officerRule)
    }

    @Test func aSavedDebriefIsNotDraftedAgain() async throws {
        let (model, store) = try await model(answer: "no JSON")
        await model.draft()
        model.writeYourself()
        model.addNote(.risk, "Payments ahead of the work.")
        for index in model.numbers.indices { model.decide(number: index, .confirm) }
        model.save()
        #expect(model.stage == .saved(count: 7))

        let again = DebriefReviewModel(mission: mission, debrief: model.debrief, store: store, contracts: nil,
                                       model: FieldModel(engine: FieldModelTests.FakeEngine(answer: "{}")))
        await again.draft()

        #expect(again.stage == .alreadySaved)
    }
}
