import CryptoKit
import Foundation

/// Signs evidence with ECDSA P-256 over SHA-256 and returns a DER signature, so any standard library
/// (the Python server included) can verify it with only the public key (ADR 0009).
protocol EvidenceSigner: Sendable {
    /// SubjectPublicKeyInfo DER: the format Python's `cryptography` loads directly.
    func publicKeyDER() throws -> Data
    func sign(_ message: Data) throws -> Data
}

/// One Secure Enclave signing key per user. The chip signs; the private key never leaves it. Its blob,
/// usable only by this phone's chip, lives in the Keychain (ChipKeyAccess), like the mission keys.
struct SecureEnclaveEvidenceSigner: EvidenceSigner {
    static let appService = "com.lubobali.missioncopilot.evidencekey"

    private let user: String
    private let items: KeychainItems

    init(user: String, service: String = appService) {
        self.user = user
        items = KeychainItems(service: service)
    }

    func publicKeyDER() throws -> Data {
        try key().publicKey.derRepresentation
    }

    func sign(_ message: Data) throws -> Data {
        try key().signature(for: message).derRepresentation
    }

    func deleteKey() throws {
        try items.delete(user)
    }

    func keyAttributes() throws -> [String: Any] {
        try items.attributes(user)
    }

    private func key() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let blob = try items.load(user) {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        }
        let created = try SecureEnclave.P256.Signing.PrivateKey(accessControl: ChipKeyAccess.make())
        if try items.add(created.dataRepresentation, account: user, access: ChipKeyAccess.make()) { return created }
        guard let raced = try items.load(user) else { throw KeychainFailure(status: errSecDuplicateItem) }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: raced)
    }
}
