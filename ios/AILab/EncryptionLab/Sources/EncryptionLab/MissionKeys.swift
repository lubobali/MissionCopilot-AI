import CryptoKit
import Foundation

/// A mission key (MK) as stored on disk: only ever wrapped, never in the clear (ADR 0008, layer C).
public struct WrappedMissionKey: Codable, Sendable, Equatable {
    public let encapsulatedKey: Data
    public let ciphertext: Data
}

public struct MissionKeyNotFound: Error, Equatable {
    public let mission: String
}

/// One wrapping key per mission. Destroying it is the crypto-shred: every copy of the wrapped
/// mission key, wherever it survived (WAL, free pages), becomes useless at once.
public protocol MissionKeyVault: Sendable {
    func wrap(_ missionKey: SymmetricKey, for mission: String) throws -> WrappedMissionKey
    func unwrap(_ wrapped: WrappedMissionKey, for mission: String) throws -> SymmetricKey
    func destroy(mission: String) throws
}

/// HPKE wrap shared by the software and Secure Enclave vaults, so tests check the same math.
enum MissionKeyWrap {
    static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256

    /// Binds the wrap to one mission: a wrapped key copied to another mission will not open.
    static func info(for mission: String) -> Data {
        Data("missioncopilot.mission-key.v1:\(mission)".utf8)
    }

    static func wrap(_ missionKey: SymmetricKey, to recipient: P256.KeyAgreement.PublicKey,
                     mission: String) throws -> WrappedMissionKey {
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info(for: mission))
        let ciphertext = try sender.seal(missionKey.withUnsafeBytes { Data($0) })
        return WrappedMissionKey(encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext)
    }

    static func unwrap<Key: HPKEDiffieHellmanPrivateKey>(_ wrapped: WrappedMissionKey, with privateKey: Key,
                                                          mission: String) throws -> SymmetricKey {
        var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: suite, info: info(for: mission),
                                           encapsulatedKey: wrapped.encapsulatedKey)
        return SymmetricKey(data: try recipient.open(wrapped.ciphertext))
    }
}

/// Encrypts one mission's files and sensitive fields with its mission key (AES-GCM, tamper-evident).
public enum MissionData {
    public struct SealFailed: Error {}

    public static func seal(_ plaintext: Data, with missionKey: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: missionKey).combined else { throw SealFailed() }
        return combined
    }

    public static func open(_ sealed: Data, with missionKey: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: missionKey)
    }
}
