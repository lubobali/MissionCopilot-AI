import Testing
@testable import MissionCopilot

/// How long the phone waits before it tries a busy server again (#104): the server's own Retry-After when it
/// gives one, kept between 5 seconds and 5 minutes; otherwise a random wait under a cap that doubles each
/// try (AWS "full jitter"), so many phones do not come back at the same second. At most 5 tries in a row.
struct BackoffTests {
    @Test(arguments: [(1, 5), (5, 5), (30, 30), (300, 300), (9_999, 300), (0, 5)])
    func theServersOwnWaitIsKeptBetweenFiveSecondsAndFiveMinutes(asked: Int, seconds: Int) {
        #expect(Backoff.delay(asked: asked, attempt: 3, jitter: { _ in 999 }) == seconds)
    }

    @Test func withoutTheServersWaitTheCapDoublesUpToFiveMinutes() {
        var caps: [Int] = []
        for attempt in 0..<8 {
            _ = Backoff.delay(asked: nil, attempt: attempt, jitter: { cap in caps.append(cap); return cap })
        }

        #expect(caps == [5, 10, 20, 40, 80, 160, 300, 300])
    }

    @Test func theRandomWaitIsNeverShorterThanFiveSeconds() {
        #expect(Backoff.delay(asked: nil, attempt: 4, jitter: { _ in 0 }) == 5)
        #expect(Backoff.delay(asked: nil, attempt: 4, jitter: { _ in 61 }) == 61)
    }

    @Test func aVeryLongRunOfTriesDoesNotOverflow() {
        #expect(Backoff.delay(asked: nil, attempt: 200, jitter: { $0 }) == 300)
    }

    @Test func atMostFiveTriesInARow() {
        #expect(Backoff.maxTries == 5)
    }
}
