import Foundation
import Security
import Testing
@testable import MissionCopilot

/// ADR 0012 decision 5: the app asks for Face ID or the passcode on every cold start and when it comes
/// back after the grace time (default 2 minutes, the organization sets 0 to 5). The lock guards the
/// data key itself: the Keychain releases it only after the person proves presence, and only while the
/// phone has a passcode.
struct AppLockTests {
    static let left = Date(timeIntervalSince1970: 1_800_000_000)

    private func asks(_ policy: AppLockPolicy = AppLockPolicy(), after seconds: TimeInterval) -> Bool {
        policy.mustAsk(coldStart: false, leftAt: Self.left, now: Self.left.addingTimeInterval(seconds))
    }

    @Test func aColdStartAlwaysAsks() {
        #expect(AppLockPolicy().mustAsk(coldStart: true, leftAt: nil, now: Self.left))
        #expect(AppLockPolicy().mustAsk(coldStart: true, leftAt: Self.left, now: Self.left))
    }

    @Test func comingBackWithinTheGraceTimeDoesNotAsk() {
        #expect(!asks(after: 119))
    }

    @Test func comingBackAtTheGraceTimeAsks() {
        #expect(asks(after: 120))
        #expect(asks(after: 3600))
    }

    @Test func graceZeroAsksOnEveryReturn() {
        #expect(asks(AppLockPolicy(graceMinutes: 0), after: 0))
    }

    @Test(arguments: [(2, 2), (0, 0), (5, 5), (7, 5), (-1, 0)])
    func theGraceTimeStaysBetweenZeroAndFiveMinutes(asked: Int, kept: Int) {
        #expect(AppLockPolicy(graceMinutes: asked).graceMinutes == kept)
    }

    @Test func aClockSetBackWhileAwayAsks() {
        #expect(asks(after: -1))
    }

    @Test func anAppThatNeverLeftDoesNotAsk() {
        #expect(!AppLockPolicy().mustAsk(coldStart: false, leftAt: nil, now: Self.left))
    }

    @Test func theDataKeyNeedsPresenceAndAPasscodeOnThisPhone() throws {
        // iOS cannot report these back from an item, so the values are pinned here.
        #expect(DataKeyAccess.accessibility == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly)
        #expect(DataKeyAccess.flags == .userPresence)
        _ = try DataKeyAccess.make()
    }
}
