import CryptoKit
import Foundation

/// One Secure Enclave signing key per user (ADR 0009). The chip signs; the private key never leaves it.
/// Its encrypted blob lives in the Keychain (this device only), like the mission vault's keys.
public struct SecureEnclaveEvidenceSigner: EvidenceSigner {
    private let user: String
    private let items: KeychainItems

    public init(user: String, service: String = "com.lubobali.missioncopilot.evidencekey") {
        self.user = user
        items = KeychainItems(service: service)
    }

    public func publicKeyDER() throws -> Data {
        try loadOrCreate().publicKey.derRepresentation
    }

    public func sign(_ message: Data) throws -> Data {
        try loadOrCreate().signature(for: message).derRepresentation
    }

    public func deleteKey() throws {
        try items.delete(user)
    }

    func keyAttributes() throws -> [String: Any] {
        try items.attributes(user)
    }

    private func loadOrCreate() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let blob = try items.load(user) {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: ChipKeyAccess.make())
        try items.add(key.dataRepresentation, account: user)
        return key
    }
}
