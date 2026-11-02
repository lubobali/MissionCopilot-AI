import Foundation
import LocalAuthentication
import Testing
@testable import MissionCopilot

/// Unlock opens the store; lock closes it (ADR 0012, #73). The real flow with stand-ins: an authenticator
/// that succeeds or fails, and a real encrypted store in a temporary folder.
@MainActor
struct AppSessionTests {
    final class FakeAuthenticator: Authenticator {
        var result: Result<LAContext, LAError>
        private(set) var calls = 0

        init(_ result: Result<LAContext, LAError>) { self.result = result }

        func authenticate() async throws -> LAContext {
            calls += 1
            return try result.get()
        }
    }

    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keys = KeychainDataKeyStore(service: "missioncopilot.tests.\(UUID().uuidString)",
                                    access: DataKeyStoreTests.plainAccess)
    let vault = SoftwareKeyVault()
    static let start = KeyLeaseTests.start

    private func session(_ result: Result<LAContext, LAError> = .success(LAContext()), now: Date = start,
                         passed: ((LAContext?) -> Void)? = nil) -> (AppSession, FakeAuthenticator) {
        let authenticator = FakeAuthenticator(result)
        let session = AppSession(authenticator: authenticator, policy: AppLockPolicy()) { [base, keys, vault] context in
            passed?(context)
            return try UserStore.openMissions(user: AppSession.localProfile, in: base, keys: keys, vault: vault,
                                              context: context, now: now)
        }
        return (session, authenticator)
    }

    @Test func theSessionStartsLockedWithNoStoreOpen() {
        let (session, _) = session()

        #expect(session.state.isLocked && session.opened == nil)
    }

    @Test func unlockingOpensTheStoreWithTheSameAuthentication() async throws {
        defer { try? keys.delete(for: AppSession.localProfile) }
        let proof = LAContext()
        var passed: LAContext?
        let (session, _) = session(.success(proof)) { passed = $0 }

        await session.unlock()

        #expect(!session.state.isLocked && session.opened != nil && session.lastError == nil)
        #expect(passed === proof)
    }

    @Test func unlockingRunsTheLeaseCheckFirstAndListsWhatItShredded() async throws {
        defer { try? keys.delete(for: AppSession.localProfile) }
        let (first, _) = session()
        await first.unlock()
        try first.opened?.missions.create(mission: "kandor-roads", title: "Kandor rural roads", now: Self.start)

        let (later, _) = session(now: Self.start.addingTimeInterval(15 * KeyLeaseTests.day))
        await later.unlock()

        #expect(later.opened?.shredded.map(\.mission) == ["kandor-roads"])
    }

    @Test(arguments: [(LAError.Code.userCancel, LockError.cancelled), (.passcodeNotSet, .noPasscode),
                      (.authenticationFailed, .failed)])
    func aFailedUnlockStaysLockedWithAClearReason(code: LAError.Code, reason: LockError) async {
        let (session, _) = session(.failure(LAError(code)))

        await session.unlock()

        #expect(session.state.isLocked && session.opened == nil && session.lastError == reason)
    }

    @Test func aSuccessfulUnlockAfterACancelClearsTheMessage() async {
        defer { try? keys.delete(for: AppSession.localProfile) }
        let (session, authenticator) = session(.failure(LAError(.userCancel)))
        await session.unlock()
        #expect(session.lastError == .cancelled)

        authenticator.result = .success(LAContext())
        await session.unlock()

        #expect(session.lastError == nil && !session.state.isLocked)
    }

    @Test func theStoreHandsTheSameAuthenticationToTheKeyStore() throws {
        // One prompt, not two: the key must be read with the proof Face ID just gave.
        struct Spy: DataKeyStore {
            let inner: KeychainDataKeyStore
            let seen: @Sendable (LAContext?) -> Void
            func loadOrCreate(for user: String, context: LAContext?) throws -> DataKey {
                seen(context)
                return try inner.loadOrCreate(for: user, context: context)
            }
            func delete(for user: String) throws { try inner.delete(for: user) }
        }
        defer { try? keys.delete(for: AppSession.localProfile) }
        let proof = LAContext()
        nonisolated(unsafe) var received: LAContext?

        _ = try UserStore.openMissions(user: AppSession.localProfile, in: base,
                                       keys: Spy(inner: keys) { received = $0 }, vault: vault, context: proof)

        #expect(received === proof)
    }

    @Test func aStoreThatCannotOpenStaysLocked() async {
        let authenticator = FakeAuthenticator(.success(LAContext()))
        let session = AppSession(authenticator: authenticator, policy: AppLockPolicy()) { _ in
            throw KeychainFailure(status: errSecInteractionNotAllowed)
        }

        await session.unlock()

        #expect(session.state.isLocked && session.opened == nil && session.lastError == .phoneLocked)
    }

    @Test func lockingDropsTheOpenStore() async {
        defer { try? keys.delete(for: AppSession.localProfile) }
        let (session, _) = session()
        await session.unlock()

        session.lock()

        #expect(session.state.isLocked && session.opened == nil)
    }

    @Test func comingBackAfterTheGraceTimeDropsTheOpenStore() async {
        defer { try? keys.delete(for: AppSession.localProfile) }
        let (session, _) = session()
        await session.unlock()

        session.sceneChanged(to: .background, at: Self.start)
        session.sceneChanged(to: .active, at: Self.start.addingTimeInterval(121))

        #expect(session.state.isLocked && session.opened == nil)
    }

    @Test func unlockingWhenAlreadyUnlockedAsksNothing() async {
        defer { try? keys.delete(for: AppSession.localProfile) }
        let (session, authenticator) = session()
        await session.unlock()

        await session.unlock()

        #expect(authenticator.calls == 1)
    }
}
