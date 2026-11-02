import CryptoKit
import Foundation
@testable import MissionCopilot

/// A software P-256 key for Simulator tests: the same signature format as the Secure Enclave signer.
struct SoftwareEvidenceSigner: EvidenceSigner {
    private let key = P256.Signing.PrivateKey()

    func publicKeyDER() throws -> Data { key.publicKey.derRepresentation }

    func sign(_ message: Data) throws -> Data { try key.signature(for: message).derRepresentation }
}
