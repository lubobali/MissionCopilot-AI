import Foundation
import Testing
@testable import MissionCopilot

/// The request number (#90): the server refuses any number that is not above the last one it took, so
/// the phone's number must always rise, survive a restart, and never fall back even if the stored
/// counter is lost (each number is at least the clock in milliseconds).
@Suite(.serialized) struct RequestCounterTests {
    let service = "missioncopilot.tests.counter.\(UUID().uuidString)"

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_793_000_000)
    }

    private func counter(_ clock: Clock = Clock(), device: String = "device-1") -> RequestCounter {
        RequestCounter(items: KeychainItems(service: service), account: device, now: { clock.now })
    }

    @Test func theFirstNumberIsTheClockInMilliseconds() async throws {
        #expect(try await counter().next() == 1_793_000_000_000)
    }

    @Test func numbersAlwaysRiseEvenWithinTheSameMillisecond() async throws {
        let counter = counter()

        let numbers = [try await counter.next(), try await counter.next(), try await counter.next()]

        #expect(numbers == [1_793_000_000_000, 1_793_000_000_001, 1_793_000_000_002])
    }

    @Test func theNumberSurvivesARestart() async throws {
        let clock = Clock()
        let first = try await counter(clock).next()
        _ = try await counter(clock).next()

        let afterRestart = try await counter(clock).next()  // a new counter, the same Keychain item

        #expect(afterRestart == first + 2)
    }

    @Test func aClockSetBackNeverMakesTheNumberFall() async throws {
        let clock = Clock()
        let before = try await counter(clock).next()
        clock.now = clock.now.addingTimeInterval(-86_400)

        #expect(try await counter(clock).next() == before + 1)
    }

    @Test func aLostCounterStillGivesAHigherNumberThanBefore() async throws {
        let clock = Clock()
        let before = try await counter(clock).next()
        try KeychainItems(service: service).delete("device-1")
        clock.now = clock.now.addingTimeInterval(1)

        #expect(try await counter(clock).next() > before)
    }

    @Test func eachPhoneIdentityHasItsOwnCounter() async throws {
        let clock = Clock()
        _ = try await counter(clock, device: "device-1").next()

        #expect(try await counter(clock, device: "device-2").next() == 1_793_000_000_000)
    }

    @Test func manyRequestsAtOnceNeverShareANumber() async throws {
        let counter = counter()

        let numbers = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<50 { group.addTask { try await counter.next() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(Set(numbers).count == 50)
    }
}
