import CryptoKit
import Foundation
import Security

/// One Secure Enclave key per mission. The chip never exports the private key; CryptoKit gives an
/// encrypted blob that only this phone's chip can use, kept in the Keychain (this device only).
/// Destroy = delete that blob: every wrapped mission key made with it can no longer be opened.
public struct SecureEnclaveKeyVault: MissionKeyVault {
    private let items: KeychainItems

    public init(service: String = "com.lubobali.missioncopilot.missionkey") {
        items = KeychainItems(service: service)
    }

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public func wrap(_ missionKey: SymmetricKey, for mission: String) throws -> WrappedMissionKey {
        let chipKey = try loadOrCreateChipKey(for: mission)
        return try MissionKeyWrap.wrap(missionKey, to: chipKey.publicKey, mission: mission)
    }

    public func unwrap(_ wrapped: WrappedMissionKey, for mission: String) throws -> SymmetricKey {
        guard let blob = try items.load(mission) else { throw MissionKeyNotFound(mission: mission) }
        let chipKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
        return try MissionKeyWrap.unwrap(wrapped, with: chipKey, mission: mission)
    }

    public func destroy(mission: String) throws {
        try items.delete(mission)
    }

    func keyAttributes(for mission: String) throws -> [String: Any] {
        try items.attributes(mission)
    }

    private func loadOrCreateChipKey(for mission: String) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if let blob = try items.load(mission) {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
        }
        let chipKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ChipKeyAccess.make())
        try items.add(chipKey.dataRepresentation, account: mission)
        return chipKey
    }
}
