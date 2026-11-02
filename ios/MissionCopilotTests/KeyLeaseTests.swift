import Foundation
import Testing
@testable import MissionCopilot

/// ADR 0012: a mission key works offline only for its lease; when the lease ends without a sync, or the
/// clock is set backwards, the mission is crypto-shredded. Every shred is recorded for the next sync.
struct KeyLeaseTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400

    private func lease(days: Int = 14, mission: String = "kandor-roads") -> KeyLease {
        KeyLease(mission: mission, renewedAt: Self.start, days: days)
    }

    @Test func aFreshLeaseIsValidForItsFullLength() {
        #expect(lease().state(now: Self.start, lastSeen: Self.start) == .valid(daysLeft: 14))
    }

    @Test func theLastSecondIsValidAndTheNextOneIsNot() {
        let end = Self.start.addingTimeInterval(14 * Self.day)

        #expect(lease().state(now: end.addingTimeInterval(-1), lastSeen: Self.start) == .valid(daysLeft: 1))
        #expect(lease().state(now: end, lastSeen: Self.start) == .ended(.expired))
    }

    @Test(arguments: [(0, 1), (14, 14), (31, 30), (-5, 1)])
    func theLengthIsKeptBetweenOneAndThirtyDays(asked: Int, kept: Int) {
        #expect(lease(days: asked).days == kept)
        #expect(KeyLease.defaultDays == 14)
    }

    @Test func aClockSetBackMoreThanFiveMinutesEndsTheLease() {
        let seen = Self.start.addingTimeInterval(Self.day)

        #expect(lease().state(now: seen.addingTimeInterval(-301), lastSeen: seen) == .ended(.clockMovedBack))
        #expect(lease().state(now: seen.addingTimeInterval(-300), lastSeen: seen) == .valid(daysLeft: 14))
    }

    @Test func aSyncRenewsTheLeaseFromThatMoment() {
        let synced = Self.start.addingTimeInterval(13 * Self.day)
        let renewed = lease().renewed(at: synced)

        #expect(renewed.state(now: synced.addingTimeInterval(13 * Self.day), lastSeen: synced) == .valid(daysLeft: 1))
    }

    @Test func theLastSeenTimeOnlyMovesForward() {
        let later = Self.start.addingTimeInterval(60)

        #expect(KeyLease.lastSeen(previous: Self.start, now: later) == later)
        #expect(KeyLease.lastSeen(previous: later, now: Self.start) == later)
    }
}
