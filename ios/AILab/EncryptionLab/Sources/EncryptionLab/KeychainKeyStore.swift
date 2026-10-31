import Foundation
import Security

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// Keeps each user's database key in the Keychain: this device only, readable only while unlocked.
public struct KeychainKeyStore: Sendable {
    let service: String

    public init(service: String = "com.lubobali.missioncopilot.dbkey") {
        self.service = service
    }

    public func loadOrCreate(for user: String) throws -> DatabaseKey {
        if let existing = try load(for: user) {
            return existing
        }
        let key = DatabaseKey.random()
        var item = baseQuery(for: user)
        item[kSecValueData as String] = key.bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, let raced = try load(for: user) {
            return raced
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return key
    }

    /// Deleting the key makes that user's database unreadable for good.
    public func delete(for user: String) throws {
        let status = SecItemDelete(baseQuery(for: user) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    func attributes(for user: String) throws -> [String: Any] {
        var query = baseQuery(for: user)
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let attributes = result as? [String: Any] else {
            throw KeychainError(status: status)
        }
        return attributes
    }

    private func load(for user: String) throws -> DatabaseKey? {
        var query = baseQuery(for: user)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw KeychainError(status: status) }
        return DatabaseKey(bytes: bytes)
    }

    private func baseQuery(for user: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: user,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
