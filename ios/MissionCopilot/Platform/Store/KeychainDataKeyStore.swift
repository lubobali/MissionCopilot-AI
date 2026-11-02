import Foundation
import Security

/// Each user's database key in the Keychain: never synced, this phone only, and in the app released
/// only after Face ID or the passcode while the phone has a passcode (DataKeyAccess, ADR 0012).
/// Tests pass another access control so the Simulator runs the same code without a prompt.
struct KeychainDataKeyStore: DataKeyStore {
    struct Failure: Error, Equatable { let status: OSStatus }

    static let app = KeychainDataKeyStore(service: "com.lubobali.missioncopilot.datakey")

    let service: String
    let usesAppRule: Bool
    private let access: @Sendable () throws -> SecAccessControl

    init(service: String, access: (@Sendable () throws -> SecAccessControl)? = nil) {
        self.service = service
        self.usesAppRule = access == nil
        self.access = access ?? DataKeyAccess.make
    }

    func loadOrCreate(for user: String) throws -> DataKey {
        if let existing = try load(user) { return DataKey(bytes: existing) }
        let key = try DataKey.random()
        var item = query(user)
        item[kSecValueData as String] = key.bytes
        item[kSecAttrAccessControl as String] = try access()
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, let raced = try load(user) {
            return DataKey(bytes: raced)  // another caller created it first: both open the same database
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return key
    }

    /// Deleting the key makes that user's database unreadable for good.
    func delete(for user: String) throws {
        let status = SecItemDelete(query(user) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    func attributes(for user: String) throws -> [String: Any] {
        var search = query(user)
        search[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        guard status == errSecSuccess, let found = result as? [String: Any] else { throw Failure(status: status) }
        return found
    }

    private func load(_ user: String) throws -> Data? {
        var search = query(user)
        search[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return data
    }

    private func query(_ user: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: user, kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
}
