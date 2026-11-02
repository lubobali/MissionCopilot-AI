import Foundation
import Testing
@testable import MissionCopilot

/// When the app is locked and when its content is covered (ADR 0012, #73). The app starts locked; coming
/// back after the grace time locks it again; the content is covered whenever the app is not in front,
/// so the app switcher never shows mission data.
struct AppLockStateTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func unlocked(_ policy: AppLockPolicy = AppLockPolicy()) -> AppLockState {
        var state = AppLockState(policy: policy)
        state.didUnlock()
        return state
    }

    private func away(_ state: inout AppLockState, seconds: TimeInterval, from: Date = start) {
        state.sceneChanged(to: .background, at: from)
        state.sceneChanged(to: .active, at: from.addingTimeInterval(seconds))
    }

    @Test func theAppStartsLocked() {
        #expect(AppLockState(policy: AppLockPolicy()).isLocked)
    }

    @Test func comingBackWithinTheGraceTimeStaysUnlocked() {
        var state = unlocked()

        away(&state, seconds: 119)

        #expect(!state.isLocked)
    }

    @Test func comingBackAfterTheGraceTimeLocks() {
        var state = unlocked()

        away(&state, seconds: 120)

        #expect(state.isLocked)
    }

    @Test func eachTimeAwayIsCountedOnItsOwn() {
        var state = unlocked()

        away(&state, seconds: 90)
        away(&state, seconds: 90, from: Self.start.addingTimeInterval(200))

        #expect(!state.isLocked)
    }

    @Test func aShortTripDoesNotCountAgainstALaterGlanceAtControlCenter() {
        var state = unlocked()
        away(&state, seconds: 30)

        state.sceneChanged(to: .inactive, at: Self.start.addingTimeInterval(600))
        state.sceneChanged(to: .active, at: Self.start.addingTimeInterval(601))

        #expect(!state.isLocked)
    }

    @Test func aClockSetBackWhileAwayLocks() {
        var state = unlocked()

        away(&state, seconds: -1)

        #expect(state.isLocked)
    }

    @Test func controlCenterOrTheAppSwitcherAloneNeverLocks() {
        var state = unlocked()

        state.sceneChanged(to: .inactive, at: Self.start)
        state.sceneChanged(to: .active, at: Self.start.addingTimeInterval(600))

        #expect(!state.isLocked)
    }

    @Test func leavingWhileLockedNeverUnlocks() {
        var state = AppLockState(policy: AppLockPolicy())

        away(&state, seconds: 1)

        #expect(state.isLocked)
    }

    @Test func lockNowLocksAtOnce() {
        var state = unlocked()

        state.lockNow()

        #expect(state.isLocked)
    }

    @Test func graceZeroLocksOnEveryReturn() {
        var state = unlocked(AppLockPolicy(graceMinutes: 0))

        away(&state, seconds: 0)

        #expect(state.isLocked)
    }

    @Test(arguments: [(AppLockState.Phase.active, false), (.inactive, true), (.background, true)])
    func theContentIsCoveredWheneverTheAppIsNotInFront(phase: AppLockState.Phase, covered: Bool) {
        var state = unlocked()
        state.sceneChanged(to: phase, at: Self.start)

        #expect(state.coversContent == covered)
    }

    @Test func aLockedAppAlwaysCoversItsContent() {
        #expect(AppLockState(policy: AppLockPolicy()).coversContent)
    }
}
