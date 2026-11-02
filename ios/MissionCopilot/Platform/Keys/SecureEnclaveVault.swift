import CryptoKit
import Foundation
import Security

/// One lock setting for every Secure Enclave key, so they cannot drift: usable only while the phone is
/// unlocked, this phone only. iOS cannot report it back from a chip key, so a test pins it.
enum ChipKeyAccess {
    static var accessibility: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
    static let flags: SecAccessControlCreateFlags = .privateKeyUsage
    /// The blob's Keychain item: same lock setting, no key-usage flag. That flag is for the chip key
    /// only; on a Keychain item a real phone refuses to return the blob (-25293, found by #74).
    static let blobFlags: SecAccessControlCreateFlags = []

    /// For creating the chip key itself.
    static func make() throws -> SecAccessControl { try access(flags) }

    /// For the Keychain item that keeps the chip key's blob.
    static func blob() throws -> SecAccessControl { try access(blobFlags) }

    private static func access(_ flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        guard let access = SecAccessControlCreateWithFlags(nil, accessibility, flags, nil) else {
            throw KeychainFailure(status: errSecParam)
        }
        return access
    }
}

/// One Secure Enclave key per mission wraps that mission's key (ADR 0008 layer C). The chip never
/// exports the private key; CryptoKit gives a blob only this phone's chip can use, kept in the
/// Keychain. Destroy = delete the blob: every wrapped key made with it can no longer be opened.
struct SecureEnclaveVault: MissionKeyVault {
    static let app = SecureEnclaveVault(service: "com.lubobali.missioncopilot.missionkey")

    let service: String
    private let items: KeychainItems

    init(service: String) {
        self.service = service
        items = KeychainItems(service: service)
    }

    func wrap(_ missionKey: SymmetricKey, for mission: String) throws -> WrappedMissionKey {
        try MissionKeyWrap.wrap(missionKey, to: chipKey(for: mission).publicKey, mission: mission)
    }

    func unwrap(_ wrapped: WrappedMissionKey, for mission: String) throws -> SymmetricKey {
        guard let blob = try items.load(mission) else { throw MissionKeyNotFound(mission: mission) }
        let chipKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
        return try MissionKeyWrap.unwrap(wrapped, with: chipKey, mission: mission)
    }

    func destroy(mission: String) throws {
        try items.delete(mission)
    }

    func keyAttributes(for mission: String) throws -> [String: Any] {
        try items.attributes(mission)
    }

    private func chipKey(for mission: String) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if let blob = try items.load(mission) {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
        }
        let created = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ChipKeyAccess.make())
        let access = try ChipKeyAccess.blob()
        if try items.add(created.dataRepresentation, account: mission, access: access) { return created }
        guard let raced = try items.load(mission) else { throw KeychainFailure(status: errSecDuplicateItem) }
        return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: raced)
    }
}
