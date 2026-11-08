import Foundation
import Testing
@testable import MissionCopilot

/// Code answers the common questions (#145, steps 6.7.12 to 6.7.14): a payment by its invoice number, the
/// total paid, the last payment, what is not done or next, whether something started or is done (with both
/// sides when the walk and the bank disagree), what was promised, the contract, the risk rating, red flags.
/// English and French. Anything else goes to the chooser (6.7.15). The answer key below must pass in full.
struct CodeAnswersTests {
    static let walk = [WordedLine(key: "bridge_started", title: "Has work on the Section 3 bridge started?",
                                  text: "Yes"),
                       WordedLine(key: "action-53f6e638bcf6", title: "Agreed action: Start the Section 3 bridge works",
                                  text: "Seen: done.")]
    static let flags = [WordedLine(key: "MC-02", title: "The same invoice paid twice",
                                   text: "No invoice reference or amount appears twice."),
                        WordedLine(key: "MC-01", title: "Payments ahead of physical progress",
                                   text: "Payments are 35 points ahead of the work built.")]
    static let sources = MissionSources.build(SourceInputs(packFiles: PackSectionsTests.files, walk: walk,
                                                           flags: flags))
    static let answers = CodeAnswers(sources: sources)

    static let contracts = "pack:sections/contracts.json#/contracts/0"
    static let invoice14 = contracts + "/payments/5"
    static let paid = contracts + "/payments#paid"
    static let action = "pack:sections/agreed-actions.json#/actions/0"

    struct Case: CustomTestStringConvertible, Sendable {
        let question: String
        /// A record the answer must cite, and words its first line must hold; nil: code does not answer.
        let cites: String?
        let says: String
        var testDescription: String { question }
    }

    static let key: [Case] = [
        Case(question: "When was invoice 14 paid?", cites: invoice14,
             says: "Invoice 14: USD 480,000, paid 12 Oct 2026."),
        Case(question: "When the invoice 14 was paid ?", cites: invoice14, says: "paid 12 Oct 2026"),
        Case(question: "How much was invoice 6?", cites: contracts + "/payments/1", says: "Invoice 6: USD 1,500,000"),
        Case(question: "How much has been paid?", cites: paid, says: "USD 8,500,000 paid to date"),
        Case(question: "How much has been paid so far?", cites: paid, says: "USD 8,500,000"),
        Case(question: "What is the total paid to the contractor?", cites: paid, says: "USD 8,500,000"),
        Case(question: "What was the last payment?", cites: invoice14, says: "Invoice 14"),
        Case(question: "What is not done?", cites: action, says: "not started"),
        Case(question: "What is next?", cites: action, says: "deadline"),
        Case(question: "Was the Section 3 bridge started?", cites: action, says: "disagree"),
        Case(question: "Is the bridge finished?", cites: action, says: "Section 3 bridge"),
        Case(question: "What did the contractor promise in May?", cites: action,
             says: "Start the Section 3 bridge works"),
        Case(question: "What is the contract value?", cites: contracts, says: "USD 10,000,000"),
        Case(question: "Who is the contractor?", cites: contracts, says: "USD 10,000,000"),
        Case(question: "What is the overall risk rating?", cites: "pack:sections/ratings.json#/overallRisk",
             says: "High"),
        Case(question: "Was any invoice paid twice?", cites: "flag:MC-02:0", says: "No invoice reference"),
        Case(question: "Are there red flags?", cites: "flag:MC-01:0", says: "Red flag"),
        Case(question: "Quand la facture 14 a-t-elle été payée ?", cites: invoice14, says: "payée le 12 Oct 2026"),
        Case(question: "Combien a été payé ?", cites: paid, says: "payés à ce jour"),
        Case(question: "Qu'est-ce qui n'est pas fait ?", cites: action, says: "pas commencé"),
        Case(question: "Le pont de la section 3 a-t-il commencé ?", cites: action, says: "désaccord"),
        Case(question: "Quel est le montant du contrat ?", cites: contracts, says: "USD 10,000,000"),
        Case(question: "Why is the contractor late?", cites: nil, says: ""),
        Case(question: "How many km of road are built?", cites: nil, says: ""),
        Case(question: "Who won the election?", cites: nil, says: "")
    ]

    @Test(arguments: key)
    func theAnswerKey(item: Case) {
        let lines = Self.answers.direct(item.question)

        guard let cites = item.cites else {
            #expect(lines == nil, "\(lines ?? [])")
            return
        }
        #expect(lines?.contains { $0.sources.contains(cites) } == true, "\(lines ?? [])")
        let all = lines?.map(\.text).joined(separator: " | ") ?? ""
        #expect(all.contains(item.says), "\(all)")
    }

    /// Short: a person on a mission reads a few lines, not a page.
    @Test func answersAreShort() {
        for item in Self.key {
            #expect((Self.answers.direct(item.question)?.count ?? 0) <= 5, "\(item.question)")
        }
    }

    /// The bank says not started, the walk says done: both are said, each with its record.
    @Test func bothSidesWhenTheWalkAndTheBankDisagree() throws {
        let lines = try #require(Self.answers.direct("Was the Section 3 bridge started?"))

        #expect(lines.first?.text == "The bank's records and your site walk disagree.")
        #expect(lines.contains { $0.sources == [Self.action] && $0.text.contains("not started") })
        #expect(lines.contains { $0.sources == ["walk:action-53f6e638bcf6"] && $0.text.contains("seen done") })
        #expect(lines.contains { $0.sources == ["walk:bridge_started"] && $0.text.contains("Yes") })
    }

    /// Without the walk's answer there is nothing to disagree about.
    @Test func noDisagreementWithoutTheWalk() throws {
        let packOnly = CodeAnswers(sources: MissionSources.build(SourceInputs(packFiles: PackSectionsTests.files)))

        let lines = try #require(packOnly.direct("Was the Section 3 bridge started?"))

        #expect(!lines.contains { $0.text.contains("disagree") })
        #expect(lines.first?.sources == [Self.action])
    }

    /// What is open: agreed actions not completed and milestones not met, never a completed one.
    @Test func whatIsOpenLeavesOutWhatIsDone() throws {
        let lines = try #require(Self.answers.direct("What is not done?"))

        #expect(lines.contains { $0.text.contains("Submit a revised work plan: ongoing") })
        #expect(lines.contains { $0.text.contains("Section 3 bridge complete: not met") })
        #expect(!lines.contains { $0.text.contains(": met ") || $0.text.contains("completed") })
    }

    @Test func anUnknownInvoiceNumberIsNotAnsweredByCode() {
        #expect(Self.answers.direct("When was invoice 99 paid?") == nil)
    }

    /// Narrow questions get narrow answers: the duplicate check alone, the overall rating alone.
    @Test func aNarrowQuestionGetsOnlyWhatItAsks() throws {
        #expect(Self.answers.direct("Was any invoice paid twice?")?.flatMap(\.sources) == ["flag:MC-02:0"])
        #expect(Self.answers.direct("What is the overall risk rating?")?.flatMap(\.sources)
                == ["pack:sections/ratings.json#/overallRisk"])
    }

    /// Six ratings, five lines: an answer is never longer than five lines.
    @Test func anAnswerIsNeverLongerThanFiveLines() throws {
        let lines = try #require(Self.answers.direct("What are the ratings?"))

        #expect(lines.count == CodeAnswers.maxLines)
        #expect(CodeAnswers.maxLines == 5)
    }

    /// A completed action is not open.
    @Test func aCompletedActionIsNotOpen() throws {
        let done = MissionSource(id: "pack:sections/agreed-actions.json#/actions/9", kind: .pack,
                                 title: "Agreed Actions › actions 10",
                                 text: "action: Clear the drains\ndeadline: 2026-05-01\nresponsible: Contractor\n"
                                     + "status: Completed",
                                 origin: .walk(question: "x"))
        let answers = CodeAnswers(sources: Self.sources + [done])

        let lines = try #require(answers.direct("What is not done?"))

        #expect(!lines.contains { $0.sources == [done.id] })
        #expect(answers.direct("What did the contractor promise?")?.contains { $0.sources == [done.id] } == true)
        #expect(answers.direct("What is done?")?.contains { $0.sources == [done.id] } == true)
    }

    /// Found on the iPhone: "What's done?" listed the site board's number ("contractor's" matched the "s" of
    /// "what's"). What is done: milestones met, completed actions, and what the walk saw done.
    @Test func whatIsDoneListsWhatIsDone() throws {
        let walk = Self.walk + [WordedLine(key: "board_number", title: "Number on the contractor's site board",
                                           text: "KN-0042")]
        let answers = CodeAnswers(sources: MissionSources.build(SourceInputs(packFiles: PackSectionsTests.files,
                                                                             walk: walk)))

        for question in ["What's done?", "What is done ?", "Qu'est-ce qui est fait ?"] {
            let lines = try #require(answers.direct(question), "\(question)")
            let cited = lines.flatMap(\.sources)

            #expect(cited.contains("pack:sections/milestones.json#/milestones/0"), "\(question)")
            #expect(cited.contains("walk:action-53f6e638bcf6"), "\(question)")
            #expect(!cited.contains("walk:board_number"), "\(question)")
            #expect(!cited.contains(Self.action), "\(question)")
        }
        // A lone letter is not a topic: "what's" does not match "contractor's".
        let started = try #require(answers.direct("What's started on the bridge?")).flatMap(\.sources)
        #expect(!started.contains("walk:board_number"))
        #expect(started.contains(Self.action))
    }

    /// Found on the iPhone: iOS Smart Punctuation types a curly apostrophe (’), and pasted text can bring curly
    /// quotes; "What’s done?" missed its answer. They read as straight ones; "done" in its short form ("don")
    /// is a status word, never a topic.
    @Test func curlyApostrophesReadAsStraightOnes() throws {
        let walk = Self.walk + [WordedLine(key: "board_number", title: "Number on the contractor's site board",
                                           text: "KN-0042")]
        let answers = CodeAnswers(sources: MissionSources.build(SourceInputs(packFiles: PackSectionsTests.files,
                                                                             walk: walk)))

        for question in ["What\u{2019}s done?", "What\u{2018}s done?", "Qu\u{2019}est-ce qui est fait ?"] {
            let cited = try #require(answers.direct(question), "\(question)").flatMap(\.sources)
            #expect(cited.contains("pack:sections/milestones.json#/milestones/0"), "\(question)")
            #expect(!cited.contains("walk:board_number"), "\(question)")
        }
        let open = try #require(answers.direct("Qu\u{2019}est-ce qui n\u{2019}est pas fait ?")).flatMap(\.sources)
        #expect(open.contains(Self.action))
        #expect(AnswerText.straight("\u{201C}done\u{201D} isn\u{2019}t") == "\"done\" isn't")
        #expect(AnswerText.saysNotAnswered("Le montant n\u{2019}est pas pr\u{E9}cis\u{E9}."))
    }

    /// "Is the bridge done?" asks about the bridge: the short form of "done" is not a topic of its own.
    @Test func theShortFormOfDoneIsNotATopic() throws {
        let walk = Self.walk + [WordedLine(key: "seen_done", title: "Anything else seen done?", text: "Fencing done")]
        let answers = CodeAnswers(sources: MissionSources.build(SourceInputs(packFiles: PackSectionsTests.files,
                                                                             walk: walk)))

        let cited = try #require(answers.direct("Is the bridge done?")).flatMap(\.sources)

        #expect(cited.contains(Self.action))
        #expect(!cited.contains("walk:seen_done"))
    }
}
