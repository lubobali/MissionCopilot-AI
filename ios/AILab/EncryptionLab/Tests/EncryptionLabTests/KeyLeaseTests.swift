import Foundation
import GRDB
import Testing
@testable import EncryptionLab

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

/// The store side: ended leases shred their missions, and "shred all" serves the shred order and the
/// officer's own button (which the organization can turn off).
struct FieldShredTests {
    private func makeStore(_ missions: [String]) throws -> MissionStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite").path
        let store = try MissionStore(db: EncryptedDatabase.open(at: path, key: DatabaseKey.random()),
                                     vault: SoftwareKeyVault())
        for mission in missions {
            try store.createMission(id: mission, title: mission)
            try store.addNote("Km 42 culvert washed out", to: mission)
        }
        return store
    }

    private func readable(_ store: MissionStore, _ mission: String) -> Bool {
        (try? store.notes(in: mission)) != nil
    }

    @Test func onlyMissionsWhoseLeaseEndedAreShredded() throws {
        let store = try makeStore(["old", "new"])
        let now = KeyLeaseTests.start.addingTimeInterval(20 * KeyLeaseTests.day)
        let leases = [KeyLease(mission: "old", renewedAt: KeyLeaseTests.start, days: 14),
                      KeyLease(mission: "new", renewedAt: now, days: 14)]

        let shredded = try store.enforce(leases: leases, now: now, lastSeen: now)

        #expect(shredded == [ShredRecord(mission: "old", reason: .leaseEnded, at: now)])
        #expect(!readable(store, "old"))
        #expect(readable(store, "new"))
    }

    @Test func aMissionWithNoLeaseIsShreddedToFailSafe() throws {
        let store = try makeStore(["unleased"])

        let shredded = try store.enforce(leases: [], now: KeyLeaseTests.start, lastSeen: KeyLeaseTests.start)

        #expect(shredded.map(\.mission) == ["unleased"])
        #expect(!readable(store, "unleased"))
    }

    @Test func aClockSetBackShredsEveryLeasedMission() throws {
        let store = try makeStore(["a", "b"])
        let seen = KeyLeaseTests.start.addingTimeInterval(KeyLeaseTests.day)
        let leases = ["a", "b"].map { KeyLease(mission: $0, renewedAt: KeyLeaseTests.start, days: 14) }

        let shredded = try store.enforce(leases: leases, now: KeyLeaseTests.start, lastSeen: seen)

        #expect(shredded.map(\.reason) == [.clockMovedBack, .clockMovedBack])
        #expect(!readable(store, "a") && !readable(store, "b"))
    }

    @Test func aShredOrderDestroysEveryMission() throws {
        let store = try makeStore(["a", "b"])

        let shredded = try store.shredAll(reason: .shredOrder, at: KeyLeaseTests.start, policy: FieldPolicy())

        #expect(shredded.map(\.mission) == ["a", "b"])
        #expect(!readable(store, "a") && !readable(store, "b"))
    }

    @Test func theOfficersOwnShredCanBeTurnedOffButAShredOrderCannot() throws {
        let store = try makeStore(["a"])
        let off = FieldPolicy(officerMayShred: false)

        #expect(throws: FieldPolicy.OfficerShredTurnedOff()) {
            try store.shredAll(reason: .officer, at: KeyLeaseTests.start, policy: off)
        }
        #expect(readable(store, "a"))
        #expect(try store.shredAll(reason: .shredOrder, at: KeyLeaseTests.start, policy: off).count == 1)
    }

    @Test func everyShredIsRecordedForTheNextSyncWithoutTheMissionsContent() throws {
        let store = try makeStore(["a"])
        _ = try store.shredAll(reason: .officer, at: KeyLeaseTests.start, policy: FieldPolicy())

        #expect(try store.shredRecords() == [ShredRecord(mission: "a", reason: .officer, at: KeyLeaseTests.start)])
    }

    @Test func aShreddedMissionIsNotShreddedOrRecordedTwice() throws {
        let store = try makeStore(["a"])
        _ = try store.shredAll(reason: .officer, at: KeyLeaseTests.start, policy: FieldPolicy())

        let again = try store.shredAll(reason: .shredOrder, at: KeyLeaseTests.start, policy: FieldPolicy())

        #expect(again.isEmpty)
        #expect(try store.shredRecords().count == 1)
    }
}
