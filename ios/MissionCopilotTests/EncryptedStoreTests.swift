import Foundation
import Testing
@testable import MissionCopilot

/// One encrypted database per user (ADR 0008 layer B, #69). The key is set on every connection, a
/// wrong key fails at open (not on a later read), and the file on disk does not look like SQLite.
/// The tests use the store's own API only: importing GRDB here would link a second SQLite.
struct EncryptedStoreTests {
    private func path() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
    }

    @Test func whatIsWrittenReadsBackWithTheSameKey() throws {
        let file = path()
        let key = try DataKey.random()
        try EncryptedStore.open(at: file, key: key).setInfo("site", "Kandor km 42")

        #expect(try EncryptedStore.open(at: file, key: key).info("site") == "Kandor km 42")
    }

    @Test func aWrongKeyFailsAtOpen() throws {
        let file = path()
        try EncryptedStore.open(at: file, key: DataKey.random()).setInfo("site", "Kandor")

        #expect(throws: EncryptedStore.Failure.wrongKey) {
            try EncryptedStore.open(at: file, key: DataKey.random())
        }
    }

    @Test func theFileOnDiskIsNotReadableSQLite() throws {
        let file = path()
        try EncryptedStore.open(at: file, key: DataKey.random()).setInfo("site", "Kandor km 42")

        let bytes = try Data(contentsOf: file)
        #expect(!bytes.starts(with: Data("SQLite format 3".utf8)))
        #expect(bytes.range(of: Data("Kandor".utf8)) == nil)
    }

    @Test func everyConnectionIsEncryptedWithSQLCipher() throws {
        let store = try EncryptedStore.open(at: path(), key: DataKey.random())

        // The pool's reader connections get the key too, not only the writer.
        #expect(try store.readerCipherVersion().hasPrefix("4.20.0"))
    }

    @Test func theSchemaIsCreatedOnceAndVersioned() throws {
        let file = path()
        let key = try DataKey.random()
        _ = try EncryptedStore.open(at: file, key: key)

        let reopened = try EncryptedStore.open(at: file, key: key)

        #expect(try reopened.appliedMigrations()
            == ["v1-store-info", "v2-missions", "v3-leases-and-shreds", "v4-evidence"])
    }
}
