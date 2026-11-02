import CryptoKit
import Foundation
import Security
import Testing
@testable import MissionCopilot

/// One Secure Enclave signing key per user signs the evidence (ADR 0009, #71): the private key never
/// leaves the chip; its blob stays in the Keychain on this phone. Runs wherever a Secure Enclave exists.
@Suite(.enabled(if: SecureEnclave.isAvailable, "Needs a Secure Enclave"))
struct EvidenceSignerTests {
    private let signer = SecureEnclaveEvidenceSigner(user: "officer-7",
                                                     service: "missioncopilot.tests.\(UUID().uuidString)")

    @Test func aChipSignedChainVerifiesWithOnlyThePublicKey() throws {
        defer { try? signer.deleteKey() }
        var chain = EvidenceChain(missionId: "kandor-roads")
        try chain.append(EvidenceChainTests.capture("photo-km42"), signer: signer)

        #expect(EvidenceChain.verify(chain.records, head: try chain.signedHead(signer: signer),
                                     publicKeyDER: try signer.publicKeyDER()) == .valid(count: 1))
    }

    @Test func theSameUserKeepsTheSameKeyAndItStaysOnThisPhone() throws {
        defer { try? signer.deleteKey() }

        #expect(try signer.publicKeyDER() == signer.publicKeyDER())
        #expect(try signer.keyAttributes()[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test func aDeletedKeyIsReplacedByANewOne() throws {
        let old = try signer.publicKeyDER()
        try signer.deleteKey()
        defer { try? signer.deleteKey() }

        #expect(try signer.publicKeyDER() != old)
    }
}
