import Foundation
import SwiftUI
import Testing
@testable import MissionCopilot

/// What the lock screen says and when the cover shows (ADR 0012, #73): the words a person sees, tested
/// as decisions, not pixels. Every message says what to do next.
struct LockScreenTests {
    @Test(arguments: [(nil, "Unlock with Face ID or your passcode to see your missions."),
                      (LockError.cancelled, "Unlock with Face ID or your passcode to see your missions."),
                      (.noPasscode, "Set a passcode on this iPhone first. Mission data stays closed without one."),
                      (.phoneLocked, "Unlock your iPhone, then try again."),
                      (.failed, "That did not work. Try again.")])
    func everyStateTellsThePersonWhatToDoNext(error: LockError?, message: String) {
        #expect(LockScreen.message(for: error) == message)
    }

    @Test(arguments: [(ScenePhase.active, AppLockState.Phase.active), (.inactive, .inactive),
                      (.background, .background)])
    func theAppsScenePhasesMapOneToOne(scene: ScenePhase, phase: AppLockState.Phase) {
        #expect(AppLockState.Phase(scene) == phase)
    }

    @Test func noNoticeWhenNothingWasShredded() {
        #expect(ShreddedNotice.text(for: []) == nil)
    }

    @Test func aNoticeSaysWhichMissionsWereDestroyedAndWhy() {
        let records = ["kandor-roads", "kandor-bridges"].map {
            ShredRecord(mission: $0, reason: .leaseEnded, time: KeyLeaseTests.start)
        }

        #expect(ShreddedNotice.text(for: records) == "2 missions were destroyed on this iPhone because "
            + "14 days passed without a sync: kandor-roads, kandor-bridges.")
        #expect(ShreddedNotice.text(for: Array(records.prefix(1)))
            == "1 mission was destroyed on this iPhone because 14 days passed without a sync: kandor-roads.")
    }

    @Test func aClockSetBackIsExplainedToo() {
        let record = ShredRecord(mission: "kandor-roads", reason: .clockMovedBack, time: KeyLeaseTests.start)

        #expect(ShreddedNotice.text(for: [record])
            == "1 mission was destroyed on this iPhone because its clock was set back: kandor-roads.")
    }
}
