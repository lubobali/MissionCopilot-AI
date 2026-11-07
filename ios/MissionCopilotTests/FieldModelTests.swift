import Foundation
import Testing
@testable import MissionCopilot

/// The one way the app asks the on-device model anything (#136, step 6.4.2): a task (a prompt and a JSON
/// schema) in; schema-valid JSON decoded, "stopped" or "refused" out. Inputs over 20,000 characters never
/// reach the model, every call runs under the time limit, a stopped answer is never used, and each call
/// starts fresh. The engine is a fake here; the real one runs on the iPhone (6.4.4).
struct FieldModelTests {
    /// A model that answers what it is told to, records what it was asked, and can be slow.
    actor FakeEngine: ModelEngine {
        var answer: String
        var delay: Duration = .zero
        private(set) var asked: [ModelRequest] = []

        init(answer: String, delay: Duration = .zero) {
            self.answer = answer
            self.delay = delay
        }

        func generate(_ request: ModelRequest) async throws -> String {
            asked.append(request)
            if delay > .zero { try await Task.sleep(for: delay) }
            return answer
        }
    }

    struct Invoice: Codable, Equatable, Sendable {
        let invoiceNumber: String
        let amountDue: Int
    }

    static let schema = #"""
        {"type":"object","additionalProperties":false,"required":["invoiceNumber","amountDue"],
         "properties":{"invoiceNumber":{"type":"string"},"amountDue":{"type":"integer"}}}
        """#

    static func task(_ prompt: String = "Read the invoice.") -> ModelTask<Invoice> {
        ModelTask(prompt: prompt, schema: schema, maxTokens: 64)
    }

    @Test func anAnswerThatFitsTheSchemaIsDecoded() async throws {
        let engine = FakeEngine(answer: #"{"invoiceNumber": "14", "amountDue": 480000}"#)

        let answer = await FieldModel(engine: engine).run(Self.task())

        #expect(answer == .answered(Invoice(invoiceNumber: "14", amountDue: 480_000)))
        #expect(await engine.asked == [ModelRequest(prompt: "Read the invoice.", schema: Self.schema, maxTokens: 64)])
    }

    @Test func anInputOverTwentyThousandCharactersNeverReachesTheModel() async throws {
        let engine = FakeEngine(answer: "{}")

        let answer = await FieldModel(engine: engine).run(Self.task(String(repeating: "x", count: 20_001)))

        #expect(answer == .refused(.inputTooLong(characters: 20_001)))
        #expect(await engine.asked.isEmpty, "the prefill cannot be stopped, so a long input is refused first")
    }

    @Test func exactlyTwentyThousandCharactersIsAllowed() async throws {
        let engine = FakeEngine(answer: #"{"invoiceNumber": "1", "amountDue": 1}"#)

        let answer = await FieldModel(engine: engine).run(Self.task(String(repeating: "x", count: 20_000)))

        #expect(answer.usable != nil)
    }

    @Test func pastTheTimeLimitTheAnswerIsStoppedAndNeverUsed() async throws {
        let engine = FakeEngine(answer: #"{"invoiceNumber": "14", "amountDue": 480000}"#, delay: .seconds(2))

        let answer = await FieldModel(engine: engine, limit: TimeLimit(.milliseconds(100))).run(Self.task())

        #expect(answer == .stopped)
        #expect(answer.usable == nil)
    }

    @Test(arguments: [
        ("not JSON", "The invoice number is 14."),
        ("a missing field", #"{"invoiceNumber": "14"}"#),
        ("a wrong type", #"{"invoiceNumber": "14", "amountDue": "a lot"}"#)
    ])
    func anAnswerThatDoesNotFitTheSchemaIsRefusedNeverGuessed(_ why: String, _ raw: String) async {
        let answer = await FieldModel(engine: FakeEngine(answer: raw)).run(Self.task())

        #expect(answer == .refused(.notSchemaValid), "\(why)")
    }

    @Test func aModelErrorIsRefusedWithItsReason() async {
        struct Broken: ModelEngine {
            func generate(_ request: ModelRequest) async throws -> String {
                throw ModelUnavailable.notInThisBuild
            }
        }

        let answer = await FieldModel(engine: Broken()).run(Self.task())

        #expect(answer == .refused(.unavailable(.notInThisBuild)))
    }

    @Test func eachCallStartsFreshWithOnlyItsOwnPrompt() async throws {
        let engine = FakeEngine(answer: #"{"invoiceNumber": "1", "amountDue": 1}"#)
        let model = FieldModel(engine: engine)

        _ = await model.run(Self.task("First page."))
        _ = await model.run(Self.task("Second page."))

        #expect(await engine.asked.map(\.prompt) == ["First page.", "Second page."])
    }

    @Test func theLimitsAreTheOnesTheThreatModelNames() {
        #expect(FieldModel.maxInputCharacters == 20_000)
        #expect(TimeLimit.model.limit == .seconds(20))
    }
}
