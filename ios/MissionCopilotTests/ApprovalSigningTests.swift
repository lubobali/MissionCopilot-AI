import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import MissionCopilot

/// The approval key and its signature (#163, step 7.3.2): a separate Secure Enclave key that asks Face ID or the
/// passcode on every signature (fresh context, no reuse); one signature per approval over canonical JSON (sorted
/// keys, like the evidence) of the draft's sentences, their facts, who and when; a cancel or a failure approves
/// nothing.
struct ApprovalSigningTests {
    static let draft = ReportDraft(id: "d1", language: "en", createdAt: Date(timeIntervalSince1970: 0), sentences: [
        Sentence(id: "s1", section: "findings", text: "Red flag MC-01: Payments are 35 points ahead.",
                 classification: .officialUseOnly, factIds: ["f2", "f1"])
    ])
    static let when = Date(timeIntervalSince1970: 1_794_268_800)  // 2026-11-10T00:00:00Z

    @Test func thePayloadIsCanonicalJSON() throws {
        let payload = try ReportApproval.payload(draft: Self.draft, mission: "m1", by: "this-phone", at: Self.when)

        #expect(String(bytes: payload, encoding: .utf8) == #"{"approvedAt":"2026-11-10T00:00:00Z","#
                + #""approvedBy":"this-phone","draftId":"d1","language":"en","mission":"m1","sentences":[{"#
                + #""factIds":["f2","f1"],"section":"findings","text":"Red flag MC-01: Payments are 35 points ahead."}"#
                + #"],"version":1}"#)
    }

    @Test func oneSignatureThatTheServerCanCheck() async throws {
        let signer = FakeApprovalSigner()

        let signed = try await ReportApproval.sign(draft: Self.draft, mission: "m1", by: "this-phone", at: Self.when,
                                                   signer: signer)

        #expect(signer.signatures == 1, "one signature per approval (iOS 26.1 race)")
        #expect(signer.reasons == [ReportApproval.reason])
        let key = try P256.Signing.PublicKey(derRepresentation: signed.publicKeyDER)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signed.signature)
        #expect(key.isValidSignature(signature, for: signed.payload), "ECDSA P-256, SHA-256, DER: as evidence.py")
        #expect(signed.payload == (try ReportApproval.payload(draft: Self.draft, mission: "m1", by: "this-phone",
                                                              at: Self.when)))
    }

    @Test func aCancelOrAFailureApprovesNothing() async {
        await #expect(throws: ReportApproval.Failure.cancelled) {
            try await ReportApproval.sign(draft: Self.draft, mission: "m1", by: "p", at: Self.when,
                                          signer: FakeApprovalSigner(.cancel))
        }
        await #expect(throws: ReportApproval.Failure.failed) {
            try await ReportApproval.sign(draft: Self.draft, mission: "m1", by: "p", at: Self.when,
                                          signer: FakeApprovalSigner(.fail))
        }
    }

    /// Cancel is the officer's choice, said plainly; anything else is a failure. Seen nested too.
    @Test func whatCountsAsACancel() {
        let cancel = { (domain: String, code: Int) in ReportApproval.isCancel(NSError(domain: domain, code: code)) }

        #expect(cancel(LAErrorDomain, LAError.userCancel.rawValue))
        #expect(cancel(LAErrorDomain, LAError.systemCancel.rawValue))
        #expect(cancel(LAErrorDomain, LAError.appCancel.rawValue))
        #expect(cancel(NSOSStatusErrorDomain, Int(errSecUserCanceled)))
        #expect(!cancel(LAErrorDomain, LAError.authenticationFailed.rawValue))
        #expect(!cancel(NSOSStatusErrorDomain, Int(errSecAuthFailed)))
        let nested = NSError(domain: "CryptoKit", code: 1, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: LAErrorDomain, code: LAError.userCancel.rawValue)
        ])
        #expect(ReportApproval.isCancel(nested))
    }

    /// The key asks every time: user presence on the chip key, only while the phone has a passcode, and each
    /// approval a fresh context that reuses no earlier Face ID.
    @Test func theKeyAsksEveryTime() {
        #expect(ApprovalKeyAccess.flags == [.privateKeyUsage, .userPresence])
        #expect(ApprovalKeyAccess.accessibility == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly)
        #expect(ApprovalKeyAccess.blobFlags == [], "the blob's item has no key-usage flag (-25293, #74)")
        let context = ApprovalKeyAccess.context(reason: ReportApproval.reason)
        #expect(context.touchIDAuthenticationAllowableReuseDuration == 0)
        #expect(context.localizedReason == "Approve the mission report")
        #expect(SecureEnclaveApprovalSigner.appService != SecureEnclaveEvidenceSigner.appService)
    }
}
