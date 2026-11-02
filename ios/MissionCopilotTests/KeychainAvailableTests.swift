import Foundation
import Security
import Testing

/// The encrypted store keeps its keys in the Keychain (ADR 0008), so its tests need one. An unsigned
/// test app gets none on the Simulator (error -34018); CI signs the tests ad hoc for that (#68).
struct KeychainAvailableTests {
    @Test func theTestAppCanWriteReadAndDeleteAKeychainItem() throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "missioncopilot.tests.keychain-check",
            kSecAttrAccount as String: UUID().uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true
        ]
        defer { SecItemDelete(item as CFDictionary) }

        #expect(SecItemAdd((item.merging([kSecValueData as String: Data("x".utf8)]) { $1 }) as CFDictionary, nil)
            == errSecSuccess)
        var found: CFTypeRef?
        let query = item.merging([kSecReturnData as String: true]) { $1 }
        #expect(SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess)
        #expect(found as? Data == Data("x".utf8))
    }
}
