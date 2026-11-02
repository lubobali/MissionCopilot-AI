import Foundation
import LocalAuthentication
import Security

struct KeychainFailure: Error, Equatable { let status: OSStatus }

/// Generic-password items under one service: this phone only, never synced, in the data-protection
/// Keychain. Shared by the database key store and the Secure Enclave vault.
struct KeychainItems: Sendable {
    let service: String

    /// - Parameter context: an authentication that already succeeded (Face ID or passcode), so iOS
    ///   releases an item protected by user presence without asking a second time.
    func load(_ account: String, context: LAContext? = nil) throws -> Data? {
        var search = query(account, context: context)
        search[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainFailure(status: status) }
        return data
    }

    /// Adds the item; false if one already exists (another caller created it first).
    func add(_ data: Data, account: String, access: SecAccessControl) throws -> Bool {
        var item = query(account, context: nil)
        item[kSecValueData as String] = data
        item[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        return true
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account, context: nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }

    func attributes(_ account: String) throws -> [String: Any] {
        var search = query(account, context: nil)
        search[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        guard status == errSecSuccess, let found = result as? [String: Any] else {
            throw KeychainFailure(status: status)
        }
        return found
    }

    func query(_ account: String, context: LAContext?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let context { query[kSecUseAuthenticationContext as String] = context }
        return query
    }
}
