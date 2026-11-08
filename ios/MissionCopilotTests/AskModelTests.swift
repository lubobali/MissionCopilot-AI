import Foundation
import Testing
@testable import MissionCopilot

/// The Ask chat, PR 1 (#145, step 6.7.3, redone after Lubo's first look: "like a BIOS from 1996"): each question
/// becomes a message with the sources found in words; the text clears after sending and with one tap; New chat
/// starts clean; example questions start a conversation. No model yet: the sources are the reply for now.
@MainActor
struct AskModelTests {
    static func model() -> AskModel {
        AskModel(sources: MissionSources.build(SourceInputs(packFiles: PackSectionsTests.files)))
    }

    @Test func aQuestionBecomesAMessageWithTheSourcesInWords() throws {
        let model = Self.model()
        model.question = "When was invoice 14 paid?"

        model.ask()

        let message = try #require(model.messages.last)
        #expect(message.question == "When was invoice 14 paid?")
        // Other payments match too, so they come grouped; the best match, invoice 14, is the first row.
        #expect(message.cards.first?.title.hasPrefix("Payments (") == true)
        #expect(message.cards.first?.lines.first == "Invoice 14 · USD 480,000 · 12 Oct 2026")
        #expect(model.question.isEmpty)  // the field clears after sending
    }

    @Test func theConversationKeepsEveryQuestionInOrder() {
        let model = Self.model()
        for question in ["Was the Section 3 bridge started?", "Who won the election?"] {
            model.question = question
            model.ask()
        }

        #expect(model.messages.map(\.question) == ["Was the Section 3 bridge started?", "Who won the election?"])
        #expect(model.messages.map(\.found) == [true, false])
        #expect(Set(model.messages.map(\.id)).count == 2)
        #expect(AskModel.nothingFound == "Nothing in this mission's data matches this question.")
    }

    @Test func clearEmptiesTheTextAndNewChatStartsClean() {
        let model = Self.model()
        model.question = "How much has been paid?"
        model.ask()
        model.question = "half typed"

        model.clear()
        #expect(model.question.isEmpty)
        #expect(model.messages.count == 1)

        model.newChat()
        #expect(model.messages.isEmpty)
        #expect(!model.canAsk)
    }

    @Test func anExampleQuestionAsksAtOnce() {
        let model = Self.model()

        model.ask(example: AskModel.examples[0])

        #expect(model.messages.map(\.question) == [AskModel.examples[0]])
        #expect(AskModel.examples.count == 3)
    }

    @Test func anEmptyQuestionDoesNothing() {
        let model = Self.model()
        model.question = "  "

        model.ask()

        #expect(model.messages.isEmpty)
    }

    @Test func eachKindOfSourceSaysWhereItCameFromInWords() {
        let walk = MissionSource(id: "walk:x", kind: .walkAnswer, title: "Q?", text: "Q? no",
                                 origin: .walk(question: "x"))
        let flag = MissionSource(id: "flag:MC-01:0", kind: .redFlag, title: "T", text: "S",
                                 origin: .redFlag(rule: "MC-01"))

        #expect(SourceWords.card(walk).place == "Your site walk")
        #expect(SourceWords.card(flag).place == "Red flag rule MC-01")
    }

    @Test func theIntroSaysHowManySourcesTheMissionHas() {
        #expect(Self.model().summary == "51 sources on this iPhone")
        #expect(AskModel(sources: []).summary == "No mission data on this iPhone yet")
    }
}
