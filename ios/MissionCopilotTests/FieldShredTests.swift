import Foundation
import Testing
@testable import MissionCopilot

/// ADR 0012 in the store (#70): each mission's lease is kept with it; enforce() shreds every mission
/// whose lease ended, every mission with no lease (fail safe), and all of them if the clock was set
/// back. Shred all serves a shred order or the officer's button (which the organization can turn off).
/// Every shred is recorded for the next sync, never with the mission's content.
struct FieldShredTests {
    static let start = KeyLeaseTests.start
    static let day = KeyLeaseTests.day

    private func store(_ missions: [String], at now: Date = start) throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let encrypted = try EncryptedStore.open(at: file, key: DataKey.random())
        let store = MissionStore(store: encrypted, vault: SoftwareKeyVault())
        for mission in missions {
            try store.create(mission: mission, title: mission, now: now)
            try store.addNote("Km 42 culvert washed out", to: mission)
        }
        return store
    }

    private func readable(_ store: MissionStore, _ mission: String) -> Bool {
        (try? store.notes(in: mission)) != nil
    }

    @Test func aNewMissionStartsAFourteenDayLease() throws {
        let store = try store(["a"])

        #expect(try store.lease(for: "a") == KeyLease(mission: "a", renewedAt: Self.start, days: 14))
    }

    @Test func onlyMissionsWhoseLeaseEndedAreShredded() throws {
        let store = try store(["old"])
        let now = Self.start.addingTimeInterval(20 * Self.day)
        try store.create(mission: "new", title: "new", now: now)

        let shredded = try store.enforce(now: now)

        #expect(shredded == [ShredRecord(mission: "old", reason: .leaseEnded, time: now)])
        #expect(!readable(store, "old"))
        #expect(try store.lease(for: "new") != nil)
    }

    @Test func aSyncRenewsTheLease() throws {
        let store = try store(["a"])
        let synced = Self.start.addingTimeInterval(13 * Self.day)

        try store.renewLease(for: "a", at: synced)

        #expect(try store.enforce(now: synced.addingTimeInterval(13 * Self.day)).isEmpty)
        #expect(readable(store, "a"))
    }

    @Test func aMissionWithNoLeaseIsShreddedToFailSafe() throws {
        let store = try store(["a"])
        try store.dropLease(for: "a")

        #expect(try store.enforce(now: Self.start).map(\.mission) == ["a"])
    }

    @Test func aClockSetBackSinceTheLastCheckShredsEveryMission() throws {
        let store = try store(["a", "b"])
        _ = try store.enforce(now: Self.start.addingTimeInterval(Self.day))

        let shredded = try store.enforce(now: Self.start)

        #expect(shredded.map(\.reason) == [.clockMovedBack, .clockMovedBack])
        #expect(!readable(store, "a") && !readable(store, "b"))
    }

    @Test func theLastSeenTimeIsKeptInTheStoreAndOnlyMovesForward() throws {
        let store = try store(["a"])
        let later = Self.start.addingTimeInterval(60)
        _ = try store.enforce(now: later)
        _ = try store.enforce(now: later.addingTimeInterval(-10))  // within 5 minutes: not shredded

        #expect(try store.lastSeen() == later)
    }

    @Test func aShredOrderDestroysEveryMission() throws {
        let store = try store(["a", "b"])

        let shredded = try store.shredAll(reason: .shredOrder, at: Self.start, policy: FieldPolicy())

        #expect(shredded.map(\.mission) == ["a", "b"])
        #expect(!readable(store, "a") && !readable(store, "b"))
    }

    @Test func theOfficersOwnShredCanBeTurnedOffButAShredOrderCannot() throws {
        let store = try store(["a"])
        let off = FieldPolicy(officerMayShred: false)

        #expect(throws: FieldPolicy.OfficerShredTurnedOff()) {
            try store.shredAll(reason: .officer, at: Self.start, policy: off)
        }
        #expect(readable(store, "a"))
        #expect(try store.shredAll(reason: .shredOrder, at: Self.start, policy: off).count == 1)
    }

    @Test func everyShredIsRecordedOnceWithoutTheMissionsContent() throws {
        let store = try store(["a"])
        _ = try store.shredAll(reason: .officer, at: Self.start, policy: FieldPolicy())
        _ = try store.shredAll(reason: .shredOrder, at: Self.start, policy: FieldPolicy())

        #expect(try store.shredRecords() == [ShredRecord(mission: "a", reason: .officer, time: Self.start)])
    }
}
