import Foundation
import Testing
import UIKit
@testable import MissionCopilot

/// The lock test of the phone proof (#74): writes keep going while the phone locks; the store must pause
/// (writes refused, never a held lock), resume after unlock, and lose nothing. Here the lock is the same
/// signals posted on a test center; the phone run proves the real one. Part of the suspension suite,
/// which takes turns with every suite whose stores pause (TakesTurnsWithThePause).
extension StoreSuspensionTests {
    private final class Locking {
        let center = NotificationCenter()
        let suspension: StoreSuspension
        let outbox: URL
        let missions: MissionStore
        let keys: KeychainDataKeyStore
        var readable = true

        init() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            outbox = root.appendingPathComponent("outbox")
            keys = KeychainDataKeyStore(service: "missioncopilot.tests.\(UUID().uuidString)",
                                        access: DataKeyStoreTests.plainAccess)
            missions = try UserStore.openMissions(user: "store-proof", in: root, keys: keys,
                                                  vault: SoftwareKeyVault()).missions
            suspension = StoreSuspension(observing: center)
        }

        func lock() {
            center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
            readable = false
        }

        func unlock() {
            readable = true
            center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
            center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        }

        @MainActor func test() throws -> StoreLockTest {
            try StoreLockTest(missions: missions, outbox: outbox, signals: center) { [unowned self] in readable }
        }

        deinit {
            unlock()
            try? keys.delete(for: "store-proof")
        }
    }

    private func passed(_ checks: [StoreProofReport.Check]) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: checks.map { ($0.name, $0.passed) })
    }

    @MainActor @Test func aLockDuringWritesPausesThenResumesWithNothingLost() throws {
        let phone = try Locking()
        let test = try phone.test()
        test.tick()
        phone.lock()
        test.tick()
        test.tick()
        phone.unlock()
        test.tick()

        let checks = test.finish()

        #expect((test.written, test.refused) == (2, 2))
        #expect(checks.map(\.name) == StoreLockTest.checkNames)
        #expect(checks.filter { !$0.passed }.isEmpty, "\(checks)")
        #expect(try phone.missions.notes(in: StoreLockTest.mission) == ["lock test 1", "lock test 2"])
    }

    @MainActor @Test func theSignalsAndPausesAreRecordedInOrder() throws {
        let phone = try Locking()
        let test = try phone.test()
        test.tick()
        phone.lock()
        test.tick()
        phone.unlock()
        test.tick()

        #expect(test.events.map(\.what) == [
            "app left the screen", "protected data going away", "writes paused", "database file unreadable",
            "protected data back", "app back on screen", "writes resumed"
        ])
    }

    @MainActor @Test func withoutALockThePauseCheckFails() throws {
        let phone = try Locking()
        let test = try phone.test()
        test.tick()

        let checks = passed(test.finish())

        #expect(checks["lock pause"] == false)
        #expect(checks["unreadable while locked"] == false)
        #expect(checks["data intact"] == true)
    }

    @MainActor @Test func aLockThatNeverEndsFailsThePauseCheck() throws {
        let phone = try Locking()
        let test = try phone.test()
        test.tick()
        phone.lock()
        test.tick()

        #expect(passed(test.finish())["lock pause"] == false)
    }

    @MainActor @Test func aSecondLockThatNeverEndsFailsThePauseCheck() throws {
        let phone = try Locking()
        let test = try phone.test()
        phone.lock()
        test.tick()
        phone.unlock()
        test.tick()
        phone.lock()
        test.tick()

        #expect(passed(test.finish())["lock pause"] == false)
    }

    @MainActor @Test func aWriteThatFailsForAnotherReasonFailsTheDataCheck() throws {
        let phone = try Locking()
        let test = try phone.test()
        try phone.missions.shred(mission: StoreLockTest.mission)
        test.tick()

        let checks = test.finish()

        #expect(passed(checks)["data intact"] == false)
        #expect(checks.first { $0.name == "data intact" }?.detail.contains("MissionKeyNotFound") == true)
    }

    @MainActor @Test func aLostNoteFailsTheDataCheck() throws {
        let phone = try Locking()
        let test = try phone.test()
        test.tick()
        test.tick()
        try phone.missions.store.rawExecuteForTests("DELETE FROM note WHERE id = (SELECT max(id) FROM note)")

        #expect(passed(test.finish())["data intact"] == false)
    }

    @MainActor @Test func aWriteRefusedForAnotherReasonFailsTheDataCheck() throws {
        let phone = try Locking()
        let test = try phone.test()
        try phone.missions.store.rawExecuteForTests(
            "CREATE TRIGGER block_notes BEFORE INSERT ON note BEGIN SELECT RAISE(FAIL, 'blocked'); END")
        test.tick()

        let checks = test.finish()

        #expect((test.written, test.refused) == (0, 0))
        #expect(passed(checks)["data intact"] == false)
    }

    @MainActor @Test func aChangedAuditLogFailsTheAuditCheck() throws {
        let phone = try Locking()
        let test = try phone.test()
        test.tick()
        try phone.missions.store.rawExecuteForTests(
            "DROP TRIGGER audit_event_no_update; UPDATE audit_event SET actor = 'someone else'")

        #expect(passed(test.finish())["audit log"] == false)
    }

    @MainActor @Test func aFileStillReadableWhileLockedFailsThatCheck() throws {
        let phone = try Locking()
        let test = try phone.test()
        phone.lock()
        phone.readable = true
        test.tick()
        phone.unlock()
        test.tick()

        #expect(passed(test.finish())["unreadable while locked"] == false)
    }

    @MainActor @Test func aRunThatNeverFinishedIsSeenOnTheNextLaunch() throws {
        let phone = try Locking()
        let test = try phone.test()

        #expect(StoreLockTest.unfinished(in: phone.outbox))
        _ = test.finish()
        #expect(!StoreLockTest.unfinished(in: phone.outbox))
    }

    @MainActor @Test func finishingSavesTheResultsForTheMac() throws {
        let phone = try Locking()
        let test = try phone.test()
        test.tick()

        let checks = test.finish()

        let saved = try JSONDecoder().decode(StoreLockTest.Results.self, from: Data(
            contentsOf: phone.outbox.appendingPathComponent(StoreLockTest.resultsFile)))
        #expect(saved.checks == checks)
        #expect(saved.written == 1)
    }
}
