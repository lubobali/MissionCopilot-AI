import Foundation
import Testing
@testable import MissionCopilot

/// The Ask chat (#145, steps 6.7.3 and 6.7.8): each question becomes a message; while the assistant works the
/// message says so; the reply is the checked answer as it was kept (or why there is none, with the sources
/// found). Follow-ups give the model earlier questions, never earlier answers. The text clears after sending
/// and with one tap; New chat starts clean and History keeps every question, newest first; Ask again keeps a
/// fresh answer as a new entry.
@MainActor
struct AskModelTests {
    typealias FakeEngine = FieldModelTests.FakeEngine

    static let sources = MissionSources.build(SourceInputs(packFiles: PackSectionsTests.files))
    static let paidOn = MissionAnswerTests.answer([("Invoice 14 was paid on 12 October 2026.", ["S1"])])

    static func model(_ engine: FakeEngine = FakeEngine(answer: paidOn), keeper: AskKeeper = .memory()) -> AskModel {
        AskModel(sources: sources, model: FieldModel(engine: engine), keeper: keeper)
    }

    @Test func aQuestionBecomesACheckedAnswerThatIsKept() async throws {
        let model = Self.model()
        model.question = "When was invoice 14 paid?"

        await model.send()

        let message = try #require(model.messages.last)
        #expect(message.question == "When was invoice 14 paid?")
        #expect(message.record?.sentences.map(\.text) == ["Invoice 14 was paid on 12 October 2026."])
        #expect(message.record?.sentences.first?.sources == [MissionAnswerTests.invoice14])
        #expect(!message.thinking && !message.notKept)
        #expect(model.history.map(\.id) == [message.record?.id].compactMap { $0 })
        #expect(model.question.isEmpty)  // the field clears after sending
    }

    @Test func whileTheAssistantWorksTheMessageSaysSoAndSendingWaits() async throws {
        let engine = FakeEngine(answer: Self.paidOn, delay: .milliseconds(300))
        let model = Self.model(engine)
        model.question = "When was invoice 14 paid?"

        let asking = Task { await model.send() }
        while model.messages.isEmpty { await Task.yield() }

        #expect(model.messages.last?.thinking == true)
        model.question = "Another one?"
        #expect(model.busy && !model.canAsk)  // typed, but the send button waits
        await model.send()  // ignored while busy
        await asking.value
        #expect(model.messages.count == 1)
        #expect(model.messages.last?.thinking == false)
    }

    /// The model sees the officer's earlier questions in this chat, never its own earlier answers.
    /// A follow-up searches with the earlier questions; the model never sees the earlier answers.
    @Test func aFollowUpFindsWhatTheEarlierQuestionAskedAbout() async throws {
        let engine = FakeEngine(answer: Self.paidOn)
        let model = Self.model(engine)

        await model.send(example: "Tell me about invoice 14")
        await model.send(example: "And when was it paid?")

        let prompt = try #require(await engine.asked.last?.prompt)
        #expect(prompt.contains("reference: Invoice 14"))
        #expect(!prompt.contains("Invoice 14 was paid on 12 October 2026."))
    }

    @Test func newChatStartsCleanAndHistoryKeepsEveryQuestionNewestFirst() async throws {
        let engine = FakeEngine(answer: Self.paidOn)
        var clock = Date(timeIntervalSince1970: 1_000)
        let model = Self.model(engine, keeper: .memory {
            clock += 60
            return clock
        })
        await model.send(example: "When was invoice 14 paid?")
        await model.send(example: "Who won the election?")

        model.newChat()
        await model.send(example: "What is the contract value?")

        #expect(model.messages.map(\.question) == ["What is the contract value?"])
        #expect(model.history.map(\.question) == ["What is the contract value?", "Who won the election?",
                                                  "When was invoice 14 paid?"])
        // After New chat, the earlier questions are no longer given to the model.
        let prompt = try #require(await engine.asked.last?.prompt)
        #expect(!prompt.contains("Earlier questions"))
        #expect(model.history[1].why == .nothingFound)
    }

    /// Ask again: a fresh answer kept as a new entry, without the questions of the chat on screen; the old one stays.
    @Test func askAgainKeepsAFreshAnswerAndTheOldOneStays() async throws {
        let engine = FakeEngine(answer: Self.paidOn)
        let model = Self.model(engine)
        await model.send(example: "When was invoice 14 paid?")
        let old = try #require(model.history.first)
        await model.send(example: "What is the overall risk rating?")

        await model.askAgain(old)

        #expect(model.history.count == 3)
        #expect(model.history.contains(old))
        #expect(model.messages.last?.question == old.question)
        #expect(model.messages.last?.record?.id != old.id)
        let prompt = try #require(await engine.asked.last?.prompt)
        #expect(!prompt.contains("Earlier questions"))
    }

    @Test func aRefusedLogStillShowsTheAnswerButSaysItWasNotKept() async throws {
        struct Refused: Error {}
        let model = Self.model(keeper: AskKeeper(keep: { _ in throw Refused() }, history: { [] }))

        await model.send(example: "When was invoice 14 paid?")

        #expect(model.messages.last?.notKept == true)
        #expect(model.messages.last?.record?.answered == true)
        #expect(model.history.isEmpty)
    }

    @Test func clearEmptiesTheTextAndAnEmptyQuestionDoesNothing() async {
        let model = Self.model()
        model.question = "half typed"

        model.clear()
        #expect(model.question.isEmpty)
        model.question = "  "
        await model.send()

        #expect(model.messages.isEmpty)
        #expect(!model.canAsk)
        #expect(AskModel.examples.count == 3)
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
        #expect(AskModel(sources: [], keeper: .memory()).summary == "No mission data on this iPhone yet")
    }

    /// The model opens with what the mission's log already keeps.
    @Test func historyOpensWithWhatTheLogKeeps() throws {
        let kept = AskRecord(AskResult(question: "Old?", found: [], why: .nothingFound), language: "en",
                             askedAt: Date(timeIntervalSince1970: 5))

        let model = Self.model(keeper: AskKeeper(keep: { _ in kept }, history: { [kept] }))

        #expect(model.history == [kept])
    }

    @Test func aKeptAnswerSaysWhenAndThatItIsBasedOnTheSourcesAtThatTime() {
        let words = AskWords.keptAt(Date(timeIntervalSince1970: 1_794_000_000))

        #expect(words.hasPrefix("Asked "))
        #expect(words.contains(" at "))
        #expect(words.hasSuffix(", based on the sources at that time"))
    }
}
