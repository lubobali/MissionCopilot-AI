import Foundation
import LocalAuthentication
import Security

/// Why an unlock did not happen. The app stays locked in every case; nothing crashes (#73).
enum LockError: Error, Equatable {
    /// The person cancelled, or chose another way.
    case cancelled
    /// The phone has no passcode, so mission data cannot be opened (ADR 0012).
    case noPasscode
    /// The phone is locked or the app is not in front: no prompt can be shown now.
    case phoneLocked
    /// Face ID or the passcode did not succeed, or anything else went wrong.
    case failed

    init(_ error: any Error) {
        if let failure = error as? KeychainFailure {
            self = failure.status == errSecInteractionNotAllowed ? .phoneLocked : .failed
            return
        }
        guard let code = (error as? LAError)?.code else {
            self = .failed
            return
        }
        self = switch code {
        case .userCancel, .appCancel, .systemCancel, .userFallback: .cancelled
        case .passcodeNotSet: .noPasscode
        case .notInteractive: .phoneLocked
        default: .failed
        }
    }
}

/// Asks the person to prove they are there and hands back that authentication, so the database key can
/// be read with it (one prompt, not two). The app uses LocalAuthenticator; tests use their own.
protocol Authenticator {
    @MainActor func authenticate() async throws -> LAContext
}

/// Face ID, with the phone's passcode as the fallback (deviceOwnerAuthentication), as ADR 0012 says.
@MainActor
final class LocalAuthenticator: Authenticator {
    nonisolated static let reason = "Unlock your missions"

    func authenticate() async throws -> LAContext {
        let context = LAContext()
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: Self.reason)
        } catch {
            throw LockError(error)
        }
        return context
    }
}
