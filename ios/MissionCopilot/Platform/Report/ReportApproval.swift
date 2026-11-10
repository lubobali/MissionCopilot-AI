import CryptoKit
import Foundation
import LocalAuthentication

/// Signs an approval (#163, step 7.3.2). The real key asks Face ID or the passcode for every signature; a fake
/// signs in tests (the Secure Enclave is not in the Simulator). Returns a DER signature, ECDSA P-256 over
/// SHA-256, the same form the server already verifies for evidence (evidence.py).
protocol ApprovalSigner: Sendable {
    /// SubjectPublicKeyInfo DER, as the evidence key.
    func publicKeyDER() throws -> Data
    func sign(_ payload: Data, reason: String) async throws -> Data
}

/// What an approval is: the exact bytes signed, the signature, and the public key that checks it.
struct SignedApproval: Sendable, Equatable {
    let payload: Data
    let signature: Data
    let publicKeyDER: Data
}

/// The officer's approval of a saved draft (#163; threat T13, MASVS-AUTH-3): canonical JSON (sorted keys, like
/// the evidence files) of the draft's sentences and their facts, who and when, signed once.
enum ReportApproval {
    enum Failure: Error, Equatable { case cancelled, failed }

    static let reason = "Approve the mission report"

    private struct Payload: Encodable {
        let version = 1
        let mission: String
        let draftId: String
        let language: String
        let sentences: [ApprovalLine]
        let approvedBy: String
        let approvedAt: String
    }

    static func payload(draft: ReportDraft, mission: String, by user: String, at time: Date) throws -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let lines = draft.sentences.map { ApprovalLine(section: $0.section, text: $0.text, factIds: $0.factIds) }
        return try WalkEvidenceFile.encoder.encode(Payload(mission: mission, draftId: draft.id,
                                                           language: draft.language, sentences: lines,
                                                           approvedBy: user, approvedAt: iso.string(from: time)))
    }

    /// One signature (two in a row can race the Face ID prompt since iOS 26.1). A cancel or a failure throws and
    /// approves nothing.
    static func sign(draft: ReportDraft, mission: String, by user: String, at time: Date,
                     signer: any ApprovalSigner) async throws -> SignedApproval {
        let payload = try payload(draft: draft, mission: mission, by: user, at: time)
        do {
            let signature = try await signer.sign(payload, reason: reason)
            return SignedApproval(payload: payload, signature: signature, publicKeyDER: try signer.publicKeyDER())
        } catch {
            throw isCancel(error) ? Failure.cancelled : Failure.failed
        }
    }

    /// The officer (or the system) stopped the prompt: Local Authentication's cancels or the Keychain's, nested too.
    static func isCancel(_ error: Error) -> Bool {
        let error = error as NSError
        let cancels: [String: Set<Int>] = [
            LAErrorDomain: [LAError.userCancel.rawValue, LAError.systemCancel.rawValue, LAError.appCancel.rawValue],
            NSOSStatusErrorDomain: [Int(errSecUserCanceled)]
        ]
        if cancels[error.domain]?.contains(error.code) == true { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(isCancel) ?? false
    }
}

/// One sentence as signed: its section, its words, the facts it cites.
private struct ApprovalLine: Encodable {
    let section: String
    let text: String
    let factIds: [String]
}

/// How the approval key is kept: on the chip, used only after Face ID or the passcode (user presence), only
/// while the phone has a passcode, never synced. Each approval opens it with a fresh context that reuses no
/// earlier Face ID, so the officer is asked every time (MASVS-AUTH-3).
enum ApprovalKeyAccess {
    static var accessibility: CFString { kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
    static let flags: SecAccessControlCreateFlags = [.privateKeyUsage, .userPresence]
    /// The blob's Keychain item: no key-usage flag (a real phone refuses that on an item, -25293, #74).
    static let blobFlags: SecAccessControlCreateFlags = []

    static func make() throws -> SecAccessControl { try access(flags) }
    static func blob() throws -> SecAccessControl { try access(blobFlags) }

    static func context(reason: String) -> LAContext {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedReason = reason
        return context
    }

    private static func access(_ flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        guard let access = SecAccessControlCreateWithFlags(nil, accessibility, flags, nil) else {
            throw KeychainFailure(status: errSecParam)
        }
        return access
    }
}

/// The approval key in the Secure Enclave, apart from the evidence key (which signs with no prompt). Making the
/// key or reading its public key asks nothing; each signature asks Face ID or the passcode.
struct SecureEnclaveApprovalSigner: ApprovalSigner {
    static let appService = "com.lubobali.missioncopilot.approvalkey"

    private let user: String
    private let items: KeychainItems

    init(user: String, service: String = appService) {
        self.user = user
        items = KeychainItems(service: service)
    }

    func publicKeyDER() throws -> Data {
        try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: try blob()).publicKey.derRepresentation
    }

    func sign(_ payload: Data, reason: String) async throws -> Data {
        let blob = try blob()
        return try await Task.detached(priority: .userInitiated) {
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: blob, authenticationContext: ApprovalKeyAccess.context(reason: reason))
            return try key.signature(for: payload).derRepresentation
        }.value
    }

    private func blob() throws -> Data {
        if let blob = try items.load(user) { return blob }
        let created = try SecureEnclave.P256.Signing.PrivateKey(accessControl: ApprovalKeyAccess.make())
        if try items.add(created.dataRepresentation, account: user, access: ApprovalKeyAccess.blob()) {
            return created.dataRepresentation
        }
        guard let raced = try items.load(user) else { throw KeychainFailure(status: errSecDuplicateItem) }
        return raced
    }
}
