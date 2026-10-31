import Foundation
import Security
import Testing
@testable import EncryptionLab

struct KeychainKeyStoreTests {
    // Unique service per test so parallel tests never share Keychain items.
    private let store = KeychainKeyStore(service: "test.\(UUID().uuidString)")

    @Test func sameUserGetsTheSameKeyEveryTime() throws {
        let first = try store.loadOrCreate(for: "amina")
        let second = try store.loadOrCreate(for: "amina")

        #expect(first == second)
        try store.delete(for: "amina")
    }

    @Test func eachUserHasTheirOwnKey() throws {
        let amina = try store.loadOrCreate(for: "amina")
        let omar = try store.loadOrCreate(for: "omar")

        #expect(amina != omar)
        try store.delete(for: "amina")
        try store.delete(for: "omar")
    }

    @Test func deletedKeyIsGoneForGood() throws {
        let old = try store.loadOrCreate(for: "amina")
        try store.delete(for: "amina")

        let new = try store.loadOrCreate(for: "amina")

        #expect(old != new)
        try store.delete(for: "amina")
    }

    @Test func keyStaysOnThisDeviceAndNeedsUnlock() throws {
        _ = try store.loadOrCreate(for: "amina")

        let attributes = try store.attributes(for: "amina")

        // Not in iCloud Keychain, not in backups restored to another phone, unreadable while locked.
        #expect(attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect((attributes[kSecAttrSynchronizable as String] as? Bool ?? false) == false)
        try store.delete(for: "amina")
    }
}
