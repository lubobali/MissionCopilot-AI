import Foundation
import Security
import Testing
@testable import MissionCopilot

/// One encrypted store per user (ADR 0008, #69): the user's protected folder, the user's key from the
/// Keychain, the database inside, always pausing on lock. The app's own settings are checked without
/// opening them: the Simulator cannot do Face ID.
struct UserStoreTests {
    private func setup() throws -> (base: URL, keys: KeychainDataKeyStore) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, KeychainDataKeyStore(service: "missioncopilot.tests.\(UUID().uuidString)",
                                           access: DataKeyStoreTests.plainAccess))
    }

    @Test func aUsersStoreLivesInTheirOwnFolderAndReopensWithItsData() throws {
        let (base, keys) = try setup()
        defer { try? keys.delete(for: "officer-7") }
        try UserStore.open(user: "officer-7", in: base, keys: keys).setInfo("site", "Kandor")

        let reopened = try UserStore.open(user: "officer-7", in: base, keys: keys)

        #expect(try reopened.info("site") == "Kandor")
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("officer-7/store.sqlite").path))
    }

    @Test func theUsersStoreAlwaysPausesOnLock() throws {
        let (base, keys) = try setup()
        defer { try? keys.delete(for: "officer-7") }

        #expect(try UserStore.open(user: "officer-7", in: base, keys: keys).isSuspendable)
    }

    @Test func twoUsersNeverShareAStoreOrAKey() throws {
        let (base, keys) = try setup()
        defer { try? keys.delete(for: "a"); try? keys.delete(for: "b") }
        try UserStore.open(user: "a", in: base, keys: keys).setInfo("site", "A only")

        #expect(try UserStore.open(user: "b", in: base, keys: keys).info("site") == nil)
        #expect(try keys.loadOrCreate(for: "a") != keys.loadOrCreate(for: "b"))
    }

    @Test func theAppKeepsStoresInApplicationSupportBehindFaceIDOrThePasscode() throws {
        let support = try #require(FileManager.default.urls(for: .applicationSupportDirectory,
                                                           in: .userDomainMask).first)

        #expect(UserStore.live.base == support.appendingPathComponent("Stores", isDirectory: true))
        #expect(UserStore.live.keys.usesAppRule)
    }
}
