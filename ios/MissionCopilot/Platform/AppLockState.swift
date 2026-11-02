import Foundation

/// Whether the app is locked and whether its content is covered (ADR 0012 decision 5, #73). Pure, so it is
/// fully tested; the app feeds it SwiftUI's scene phase. It starts locked; coming back after the grace
/// time (AppLockPolicy) locks again. Control Center or the app switcher alone ("inactive") never starts
/// the clock, but the content is covered whenever the app is not in front, so the switcher shows nothing.
struct AppLockState: Equatable, Sendable {
    enum Phase: Sendable { case active, inactive, background }

    private(set) var isLocked = true
    private(set) var phase = Phase.active
    private var leftAt: Date?
    let policy: AppLockPolicy

    init(policy: AppLockPolicy) {
        self.policy = policy
    }

    /// Covered when not in front (the app switcher snapshot) or locked (only the lock screen shows).
    var coversContent: Bool { isLocked || phase != .active }

    mutating func sceneChanged(to newPhase: Phase, at now: Date) {
        if newPhase == .background { leftAt = now }
        if newPhase == .active, let left = leftAt {
            if policy.mustAsk(coldStart: false, leftAt: left, now: now) { isLocked = true }
            leftAt = nil
        }
        phase = newPhase
    }

    /// After Face ID or the passcode succeeded and the database key was released.
    mutating func didUnlock() {
        isLocked = false
    }

    mutating func lockNow() {
        isLocked = true
    }
}
