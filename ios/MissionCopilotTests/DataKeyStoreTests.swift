import Foundation
import Security
import Testing
@testable import MissionCopilot

/// Each user's database key lives in the Keychain (ADR 0008 layer B, #69). In the app it is released
/// only after Face ID or the passcode (DataKeyAccess); these tests pass a plain access control so the
/// Simulator can run the same code without a prompt.
struct DataKeyStoreTests {
    @Sendable static func plainAccess() throws -> SecAccessControl {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [], nil)
        else { throw DataKeyAccess.Failed() }
        return access
    }

    private func store() throws -> KeychainDataKeyStore {
        KeychainDataKeyStore(service: "missioncopilot.tests.\(UUID().uuidString)", access: Self.plainAccess)
    }

    @Test func theFirstOpenCreatesAKeyAndLaterOpensGetTheSameOne() throws {
        let keys = try store()
        defer { try? keys.delete(for: "officer-7") }

        let first = try keys.loadOrCreate(for: "officer-7")

        #expect(try keys.loadOrCreate(for: "officer-7") == first)
        #expect(first.bytes.count == 32)
        #expect(first.bytes != Data(count: 32))
    }

    @Test func manyOpensAtOnceAllGetTheSameKey() async throws {
        let keys = try store()
        defer { try? keys.delete(for: "officer-7") }

        let opened = try await withThrowingTaskGroup(of: DataKey.self) { group in
            for _ in 0..<20 { group.addTask { try keys.loadOrCreate(for: "officer-7") } }
            return try await group.reduce(into: [DataKey]()) { $0.append($1) }
        }

        #expect(Set(opened.map(\.bytes)).count == 1)
    }

    @Test func everyUserHasTheirOwnKey() throws {
        let keys = try store()
        defer { try? keys.delete(for: "a"); try? keys.delete(for: "b") }

        #expect(try keys.loadOrCreate(for: "a") != keys.loadOrCreate(for: "b"))
    }

    @Test func aDeletedKeyIsGoneForGood() throws {
        let keys = try store()
        let old = try keys.loadOrCreate(for: "officer-7")

        try keys.delete(for: "officer-7")
        defer { try? keys.delete(for: "officer-7") }

        #expect(try keys.loadOrCreate(for: "officer-7") != old)
    }

    @Test func theKeyNeverSyncsAndStaysOnThisPhone() throws {
        let keys = try store()
        defer { try? keys.delete(for: "officer-7") }
        _ = try keys.loadOrCreate(for: "officer-7")

        let attributes = try keys.attributes(for: "officer-7")

        #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)
        // Our access control was applied, not the system default ("when unlocked", which can migrate).
        #expect(attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test func theRawKeyFormSkipsPasswordStretching() {
        let key = DataKey(bytes: Data(repeating: 0xAB, count: 32))

        #expect(key.rawKeyLiteral == "x'" + String(repeating: "ab", count: 32) + "'")
    }

    @Test func theAppUsesThePresenceAndPasscodeRule() throws {
        #expect(KeychainDataKeyStore.app.service == "com.lubobali.missioncopilot.datakey")
        #expect(KeychainDataKeyStore.app.usesAppRule)
        #expect(try !store().usesAppRule)
    }
}
