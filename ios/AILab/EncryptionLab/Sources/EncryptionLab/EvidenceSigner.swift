import CryptoKit
import Foundation

/// Signs evidence with ECDSA P-256 / SHA-256 and returns a DER signature, so any standard library
/// (the Python backend included) can verify it with only the public key (ADR 0009).
public protocol EvidenceSigner: Sendable {
    /// SubjectPublicKeyInfo DER: the format Python's `cryptography` loads directly.
    func publicKeyDER() throws -> Data
    func sign(_ message: Data) throws -> Data
}

/// Software P-256 key for Simulator tests; same signature format as the Secure Enclave signer.
public struct SoftwareEvidenceSigner: EvidenceSigner {
    private let key = P256.Signing.PrivateKey()

    public init() {}

    public func publicKeyDER() throws -> Data { key.publicKey.derRepresentation }

    public func sign(_ message: Data) throws -> Data { try key.signature(for: message).derRepresentation }
}
