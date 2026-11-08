import Foundation
import Testing
@testable import MissionCopilot

/// The checks on every answer sentence (#145, step 6.7.5), pure code: a source found must be cited; numbers,
/// dates and months must be in the sources cited; at least half of the main words must be there; and a
/// sentence must not say the opposite of them. A sentence that fails is left out with its reason; with none
/// left, the app says the mission's data does not answer the question and shows the sources found.
struct AnswerCheckTests {
    typealias FakeEngine = FieldModelTests.FakeEngine

    static let sources = MissionAnswerTests.sources
    static let invoice14 = MissionAnswerTests.invoice14
    static let paid = "pack:sections/contracts.json#/contracts/0/payments#paid"
    static let action = "pack:sections/agreed-actions.json#/actions/0"
    static let progress = "doc:documents/progress-report-2026-09.md#3"

    static func reason(_ text: String, _ ids: [String], found: [MissionSource] = sources) -> String? {
        AnswerCheck.reason(text, cites: ids, found: found)
    }

    static func walk(_ answer: String) -> MissionSource {
        MissionSource(id: "walk:bridge_started", kind: .walkAnswer,
                      title: "Has work on the Section 3 bridge started?",
                      text: "Has work on the Section 3 bridge started? \(answer)",
                      origin: .walk(question: "bridge_started"))
    }

    @Test func aSentenceItsSourcesBackPasses() {
        #expect(Self.reason("Invoice 14 was paid on 12 October 2026.", [Self.invoice14]) == nil)
        #expect(Self.reason("Invoice 14 was for USD 480,000.", [Self.invoice14]) == nil)
        #expect(Self.reason("The contractor has been paid USD 8.5 million in all.", [Self.paid]) == nil)
        #expect(Self.reason("Le contrat a reçu 8 500 000 USD.", [Self.paid]) == nil)
        #expect(Self.reason("La facture 14 a été payée le 12 octobre 2026.", [Self.invoice14]) == nil)
        #expect(Self.reason("The agreed action to start the Section 3 bridge works has not started.",
                            [Self.action]) == nil)
    }

    @Test func aSentenceMustCiteASourceThatWasFound() {
        #expect(Self.reason("Invoice 14 was paid on 12 October 2026.", []) == "It cites no source that was found.")
        #expect(Self.reason("Invoice 14 was paid.", ["pack:not-found"]) == "It cites no source that was found.")
    }

    @Test func numbersAndMonthsMustBeInTheSourcesCited() {
        #expect(Self.reason("Invoice 14 was for USD 48,000.", [Self.invoice14])
                == "The number 48000 is not in the sources it cites.")
        #expect(Self.reason("The contractor was paid five million dollars.", [Self.paid])
                == "The number 5000000 is not in the sources it cites.")
        #expect(Self.reason("Invoice 14 was paid on 12 November 2026.", [Self.invoice14])
                == "The month November is not in the sources it cites.")
        // Another source holds the number, but it is not the one cited.
        #expect(Self.reason("Invoice 14 was for USD 480,000.", [Self.paid]) != nil)
        // "may" as a verb is not a month; before a number it is one, written small or not.
        #expect(Self.reason("Invoice 14 may have been paid on 12 October 2026.", [Self.invoice14]) == nil)
        #expect(Self.reason("Invoice 14 was paid on may 12, 2026.", [Self.invoice14])
                == "The month May is not in the sources it cites.")
        // A date's leading zero is the same number: 5 March is "2026-03-05".
        let early = MissionSource(id: "pack:p", kind: .pack, title: "Payment", text: "amount: 20000\ndate: 2026-03-05",
                                  origin: .walk(question: "p"))
        #expect(Self.reason("USD 20,000 was paid on 5 March 2026.", [early.id], found: [early]) == nil)
    }

    /// A sentence with numbers keeps as tags only the sources that hold them (in the order found).
    @Test func onlyTheSourcesHoldingTheNumbersAreTags() {
        let both = Self.sources.map(\.id).filter { [Self.action, Self.progress].contains($0) }

        #expect(AnswerCheck.check("Invoice 14 was paid on 12 October 2026.", cites: [Self.invoice14, Self.paid],
                                  found: Self.sources) == .backed([Self.invoice14]))
        #expect(AnswerCheck.check("The Section 3 bridge works have not started.", cites: [Self.action, Self.progress],
                                  found: Self.sources) == .backed(both))
        #expect(both.count == 2)
    }

    /// Every status word must be in the sources cited, in any form: "payments" backs "paid". A pack record's
    /// label names a target, it does not say it was reached (milestone "Section 3 bridge complete" is notMet,
    /// the indicator "Bridges completed" is 0).
    @Test func statusWordsMustBeInTheSourcesCited() {
        let milestone = "pack:sections/milestones.json#/milestones/2"
        let indicator = "pack:sections/results.json#/indicators/2"
        #expect(Self.reason("The Section 3 bridge is completed.", [milestone])
                == "The word “completed” is not in the sources it cites.")
        #expect(Self.reason("The Section 3 bridge is completed.", [indicator]) != nil)
        #expect(Self.reason("The payment risk on invoice 14 should not be raised.", [Self.invoice14])
                == "The word “raised” is not in the sources it cites.")
        #expect(Self.reason("Invoice 14 was approved on 12 October 2026.", [Self.invoice14])
                == "The word “approved” is not in the sources it cites.")
        #expect(Self.reason("Invoice 14 was paid on 12 October 2026.", [Self.invoice14]) == nil)
    }

    @Test func spokenAmountsAreNumbers() {
        let note = MissionSource(id: "fact:n", kind: .note, title: "Debrief note · Risk",
                                 text: "Correction: the invoice amount is forty eight thousand dollars.",
                                 origin: .fact(id: "n", sources: []))

        #expect(Self.reason("The invoice amount is USD 48,000.", [note.id], found: [note]) == nil)
        #expect(Self.reason("The invoice amount is USD 480,000.", [note.id], found: [note])
                == "The number 480000 is not in the sources it cites.")
    }

    @Test func mostMainWordsMustBeInTheSourcesCited() {
        #expect(Self.reason("The contractor dug the tunnel ahead of schedule.", [Self.invoice14])
                == "Its words do not match the sources it cites.")
    }

    @Test func aSentenceCannotSayTheOppositeOfItsSources() {
        let opposite = "It says the opposite of the sources it cites."
        let walkYes = Self.walk("yes"), walkNo = Self.walk("no")
        let started = "Work on the Section 3 bridge has started."
        let notStarted = "Work on the Section 3 bridge has not started."

        #expect(Self.reason("The Section 3 bridge works have started.", [Self.action]) == opposite)
        // Finished means started: works the bank says have not started cannot be completed.
        #expect(Self.reason("The Section 3 bridge works are completed.", [Self.action]) == opposite)
        #expect(Self.reason(started, [walkYes.id], found: [walkYes]) == nil)
        #expect(Self.reason(started, [walkNo.id], found: [walkNo]) == opposite)
        #expect(Self.reason(notStarted, [walkNo.id], found: [walkNo]) == nil)
        #expect(Self.reason(notStarted, [walkYes.id], found: [walkYes]) == opposite)
    }

    /// Both sides, each cited: the walk says started, the bank says not started.
    @Test func aSentenceGivingBothSidesPasses() {
        let yes = Self.walk("yes")
        let found = Self.sources + [yes]

        #expect(Self.reason("The bank record says the Section 3 bridge works have not started, but your site walk "
                            + "says work has started.", [Self.action, yes.id], found: found) == nil)
    }

    /// Small models often write the label in the text too: it is taken out before the checks and the screen.
    @Test func labelsWrittenInTheTextAreTakenOut() async {
        let engine = FakeEngine(answer: MissionAnswerTests.answer([("Invoice 14 was paid on 12 October 2026 (S1) [S1].",
                                                                    ["S1"])]))

        let result = await MissionAnswerTests.ask("When was invoice 14 paid?", engine: engine)

        #expect(result.sentences.map(\.text) == ["Invoice 14 was paid on 12 October 2026."])
    }

    @Test func failedSentencesAreLeftOutWithTheirReason() async {
        let engine = FakeEngine(answer: MissionAnswerTests.answer([
            ("Invoice 14 was paid on 12 October 2026.", ["S1"]),
            ("Invoice 14 was for USD 48,000.", ["S1"])
        ]))

        let result = await MissionAnswerTests.ask("When was invoice 14 paid?", engine: engine)

        #expect(result.sentences.map(\.text) == ["Invoice 14 was paid on 12 October 2026."])
        #expect(result.leftOut == [LeftOutSentence(text: "Invoice 14 was for USD 48,000.", sources: [Self.invoice14],
                                                   reason: "The number 48000 is not in the sources it cites.")])
        #expect(result.why == nil)
    }

    @Test func withNoSentenceLeftTheDataDoesNotAnswer() async {
        let engine = FakeEngine(answer: MissionAnswerTests.answer([("Invoice 14 was for USD 48,000.", ["S1"])]))

        let result = await MissionAnswerTests.ask("When was invoice 14 paid?", engine: engine)

        #expect(result.sentences.isEmpty)
        #expect(result.leftOut.count == 1)
        #expect(result.why == .noneBacked)
        #expect(!result.found.isEmpty)
        #expect(AskResult.Why.noneBacked.words.contains("not backed"))
    }
}
