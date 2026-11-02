import Foundation
import LocalAuthentication
import Observation

/// The app lock in action (ADR 0012, #73): unlock asks for Face ID or the passcode, then opens the user's
/// missions with that same authentication (one prompt), running the lease check first. Locking, or coming
/// back after the grace time, drops the open store, so nothing is readable behind the lock screen. Any
/// failure leaves the app locked with a clear reason.
@MainActor @Observable
final class AppSession {
    /// Until sign-in (Phase 8) the store opens for one local profile on this phone.
    nonisolated static let localProfile = "this-phone"

    private(set) var state: AppLockState
    private(set) var opened: UserStore.Opened?
    private(set) var lastError: LockError?

    private let authenticator: any Authenticator
    private let openStore: @MainActor (LAContext) throws -> UserStore.Opened

    init(authenticator: any Authenticator, policy: AppLockPolicy,
         openStore: @escaping @MainActor (LAContext) throws -> UserStore.Opened) {
        self.authenticator = authenticator
        self.state = AppLockState(policy: policy)
        self.openStore = openStore
    }

    func unlock() async {
        guard state.isLocked else { return }  // already open: never a second prompt
        do {
            let proof = try await authenticator.authenticate()
            opened = try openStore(proof)
            state.didUnlock()
            lastError = nil
        } catch {
            lastError = LockError(error)  // still locked, so no store is open
        }
    }

    func lock() {
        state.lockNow()
        opened = nil
    }

    func sceneChanged(to phase: AppLockState.Phase, at now: Date) {
        state.sceneChanged(to: phase, at: now)
        if state.isLocked { opened = nil }
    }
}
