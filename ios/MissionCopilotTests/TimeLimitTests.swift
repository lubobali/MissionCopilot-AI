import Foundation
import Synchronization
import Testing
@testable import MissionCopilot

/// Every model call has a time limit (threat T06, #62). Within it the answer is used; past it the call is
/// cancelled and the app gets "stopped" at once, even if the call ignores cancellation. A stopped call is
/// never used as facts: the item goes to a person for review.
struct TimeLimitTests {
    struct Boom: Error, Equatable {}

    private func elapsed<T>(_ body: () async throws -> T) async rethrows -> (T, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await body()
        return (value, clock.now - start)
    }

    @Test func anAnswerWithinTheLimitIsUsed() async throws {
        let outcome = try await TimeLimit(.seconds(1)).run { "facts" }

        #expect(outcome == .answered("facts"))
        #expect(outcome.usable == "facts" && !outcome.needsReview)
    }

    @Test func aSlowCallIsStoppedAndCancelled() async throws {
        let sawCancel = Mutex(false)

        let (outcome, took) = try await elapsed {
            try await TimeLimit(.milliseconds(200)).run { () async throws -> String in
                do { try await Task.sleep(for: .seconds(5)) } catch { sawCancel.withLock { $0 = true } }
                return "late"
            }
        }
        try await Task.sleep(for: .milliseconds(100))  // let the cancelled call notice

        #expect(outcome == .stopped)
        #expect(took < .seconds(1))
        #expect(sawCancel.withLock { $0 })
    }

    @Test func aCallThatIgnoresCancelStillCannotHoldTheAppHostage() async throws {
        let (outcome, took) = try await elapsed {
            try await TimeLimit(.milliseconds(200)).run { () async throws -> String in
                let end = ContinuousClock.now + .seconds(2)
                while ContinuousClock.now < end {}  // busy, never checks for cancel
                return "late"
            }
        }

        #expect(outcome == .stopped)
        #expect(took < .seconds(1))
    }

    @Test func aStoppedCallIsNeverUsedAsFacts() {
        let outcome = ModelOutcome<String>.stopped

        #expect(outcome.usable == nil && outcome.needsReview)
    }

    @Test func aCallThatFailsBeforeTheLimitReportsItsError() async {
        await #expect(throws: Boom()) {
            _ = try await TimeLimit(.seconds(1)).run { () async throws -> String in throw Boom() }
        }
    }

    @Test func modelCallsGetTwentySeconds() {
        // Normal pages take 3 to 6 s on the iPhone 13 Pro Max (#48): a wide margin, never an hour.
        #expect(TimeLimit.model.limit == .seconds(20))
    }
}
