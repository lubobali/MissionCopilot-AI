import Foundation

/// The phone's two Secure Enclave keys for one user: the evidence key and the Face ID approval key (#163).
/// A shred order and a new connection forget both (found on the iPhone, Nov 11 2026): the server keeps an
/// approval key for the phone that registered it, so a key kept past a revoke could never be registered by the
/// phone connected next, and its approved report would wait forever.
struct PhoneKeys: Sendable {
    let user: String
    var evidenceService = SecureEnclaveEvidenceSigner.appService
    var approvalService = SecureEnclaveApprovalSigner.appService

    func forget() {
        for service in [evidenceService, approvalService] {
            try? KeychainItems(service: service).delete(user)
        }
    }
}
