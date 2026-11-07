import Foundation
import Testing
@testable import MissionCopilot

/// "Test the AI assistant" on Before you go (#136, step 6.4.5): one fixed fictional extraction (spike #13's
/// Kandor invoice and progress report, 8 facts), offline, checked by code against the true values, with the
/// time it took. Nothing is stored.
struct ModelSelfTestTests {
    static let truth = #"""
        {"invoiceNumber":"14","invoiceDate":"2026-10-12","amountDue":480000,"cumulativePaid":8500000,
         "contractValue":10000000,"kmCompleted":32,"kmTotal":64,"bridgeStatus":"not_started"}
        """#

    static func model(_ answer: String, delay: Duration = .zero, limit: TimeLimit = .model) -> FieldModel {
        FieldModel(engine: FieldModelTests.FakeEngine(answer: answer, delay: delay), limit: limit)
    }

    @Test func theTrueAnswerIsEightOfEight() async {
        let result = await ModelSelfTest.run(Self.model(Self.truth))

        guard case .answered(_, let right) = result else { Issue.record("\(result)"); return }
        #expect(right == 8)
    }

    @Test func eachWrongFactIsCounted() async {
        let wrong = Self.truth.replacingOccurrences(of: "480000", with: "48000")
            .replacingOccurrences(of: "not_started", with: "completed")

        let result = await ModelSelfTest.run(Self.model(wrong))

        guard case .answered(_, let right) = result else { Issue.record("\(result)"); return }
        #expect(right == 6)
    }

    @Test func pastTheLimitItSaysStopped() async {
        let result = await ModelSelfTest.run(Self.model(Self.truth, delay: .seconds(2),
                                                        limit: TimeLimit(.milliseconds(100))))

        #expect(result == .stopped)
    }

    @Test func aModelThatCannotAnswerSaysWhy() async {
        struct Missing: ModelEngine {
            func generate(_ request: ModelRequest) async throws -> String { throw ModelUnavailable.notInThisBuild }
        }

        #expect(await ModelSelfTest.run(FieldModel(engine: Missing())) == .refused(.unavailable(.notInThisBuild)))
    }

    @Test func theTaskIsSpikeThirteensDocumentsWithinTheInputCap() {
        #expect(ModelSelfTest.task.prompt.contains("INVOICE No. 14"))
        #expect(ModelSelfTest.task.prompt.contains("Completed: 32 km asphalt"))
        #expect(ModelSelfTest.task.prompt.count < FieldModel.maxInputCharacters)
        #expect(ModelSelfTest.task.schema.contains(#""bridgeStatus":{"type":"string","enum""#))
    }

    @Test func theResultInWords() {
        #expect(ModelSelfTest.Result.answered(seconds: 3.64, right: 8).words
                == "Answered in 3.6 s · 8 of 8 facts right")
        #expect(ModelSelfTest.Result.answered(seconds: 4, right: 7).words
                == "Answered in 4.0 s · 7 of 8 facts right. Check its facts on site.")
        #expect(ModelSelfTest.Result.stopped.words
                == "It did not answer within 20 s, so it stopped. Try again; if it keeps stopping, restart the iPhone.")
        #expect(ModelSelfTest.Result.refused(.unavailable(.couldNotLoad)).words
                == "It could not start. Close other apps and try again.")
    }

    @Test func onlyAllEightRightCountsAsPassed() {
        #expect(ModelSelfTest.Result.answered(seconds: 3, right: 8).passed)
        #expect(!ModelSelfTest.Result.answered(seconds: 3, right: 7).passed)
        #expect(!ModelSelfTest.Result.stopped.passed)
    }

    @Test func onlyAVerifiedModelOffersTheTest() {
        let words = MissionWords()
        let ready = BeforeYouGo(pack: .ready(updated: Date()), facts: nil, model: .verified(files: 7), speech: [:],
                                freeBytes: 9_000_000_000, words: words)
        let missing = BeforeYouGo(pack: .ready(updated: Date()), facts: nil, model: .notInThisBuild, speech: [:],
                                  freeBytes: 9_000_000_000, words: words)

        #expect(ready.lines[1].testsModel)
        #expect(!missing.lines[1].testsModel)
    }
}

/// Readiness runs the self-test and keeps its result for the card.
@MainActor
struct ReadinessSelfTestTests {
    @Test func theSelfTestRunsAndItsResultIsKept() async {
        let readiness = Readiness(model: { .verified(files: 7) }, speech: FakeSpeechFiles([:]),
                                  freeBytes: { 9_000_000_000 },
                                  fieldModel: ModelSelfTestTests.model(ModelSelfTestTests.truth))
        #expect(readiness.selfTest == .idle)

        await readiness.testModel()

        guard case .done(.answered(_, let right)) = readiness.selfTest else {
            Issue.record("\(readiness.selfTest)")
            return
        }
        #expect(right == 8)
    }
}
