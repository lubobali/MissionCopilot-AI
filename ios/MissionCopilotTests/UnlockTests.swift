import Foundation
import LocalAuthentication
import Security
import Testing
@testable import MissionCopilot

/// Face ID or the passcode, then the database key read with that same authentication (ADR 0012, #73).
/// Every way it can fail is one clear LockError and the app stays locked; nothing crashes. The real
/// prompt needs a real phone (#73 step 5); here: the error mapping and the one-prompt key lookup.
struct UnlockTests {
    @Test(arguments: [(LAError.Code.userCancel, LockError.cancelled), (.appCancel, .cancelled),
                      (.systemCancel, .cancelled), (.userFallback, .cancelled), (.passcodeNotSet, .noPasscode),
                      (.biometryLockout, .failed), (.authenticationFailed, .failed), (.notInteractive, .phoneLocked)])
    func everyAuthenticationFailureBecomesOneClearReason(code: LAError.Code, reason: LockError) {
        #expect(LockError(LAError(code)) == reason)
    }

    @Test func aLockedPhoneInTheKeychainIsPhoneLockedNotACrash() {
        #expect(LockError(KeychainFailure(status: errSecInteractionNotAllowed)) == .phoneLocked)
        #expect(LockError(KeychainFailure(status: errSecAuthFailed)) == .failed)
        #expect(LockError(CocoaError(.fileNoSuchFile)) == .failed)
    }

    @Test func theKeyLookupCarriesTheAuthenticationSoThereIsOnePrompt() {
        let context = LAContext()
        let items = KeychainItems(service: "missioncopilot.tests")

        let query = items.query("officer-7", context: context)

        #expect(query[kSecUseAuthenticationContext as String] as? LAContext === context)
        #expect(items.query("officer-7", context: nil)[kSecUseAuthenticationContext as String] == nil)
    }

    @Test func theKeyStillReadsBackWhenAnAuthenticationIsPassedIn() throws {
        let keys = KeychainDataKeyStore(service: "missioncopilot.tests.\(UUID().uuidString)",
                                        access: DataKeyStoreTests.plainAccess)
        defer { try? keys.delete(for: "officer-7") }
        let created = try keys.loadOrCreate(for: "officer-7")

        #expect(try keys.loadOrCreate(for: "officer-7", context: LAContext()) == created)
    }

    @Test func thePromptSaysWhyInPlainWords() {
        #expect(LocalAuthenticator.reason == "Unlock your missions")
    }
}
