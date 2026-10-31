import CryptoKit
import Foundation
import Security
import Testing
@testable import EncryptionLab

@Suite(.enabled(if: SecureEnclave.isAvailable, "No Secure Enclave here, proven on device"))
struct SecureEnclaveEvidenceSignerTests {
    private let service = "test.\(UUID().uuidString)"

    @Test func chainSignedByTheChipVerifiesWithOnlyThePublicKey() throws {
        let signer = SecureEnclaveEvidenceSigner(user: "amina", service: service)
        var chain = EvidenceChain(missionId: "kandor-roads")
        try chain.append(file: Data("photo-km42".utf8), capturedAt: Date(), signer: signer)
        try chain.append(file: Data("photo-km43".utf8), capturedAt: Date(), signer: signer)

        let result = EvidenceChain.verify(chain.records, head: try chain.signedHead(signer: signer),
                                          publicKeyDER: try signer.publicKeyDER())

        #expect(result == .valid(count: 2))
        try signer.deleteKey()
    }

    @Test func sameUserKeepsTheSameKey() throws {
        let first = try SecureEnclaveEvidenceSigner(user: "amina", service: service).publicKeyDER()
        let second = try SecureEnclaveEvidenceSigner(user: "amina", service: service).publicKeyDER()

        #expect(first == second)
        try SecureEnclaveEvidenceSigner(user: "amina", service: service).deleteKey()
    }

    @Test func chipKeyBlobStaysOnThisDeviceAndNeedsUnlock() throws {
        let signer = SecureEnclaveEvidenceSigner(user: "amina", service: service)
        _ = try signer.publicKeyDER()

        let attributes = try signer.keyAttributes()

        #expect(attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        try signer.deleteKey()
    }
}
