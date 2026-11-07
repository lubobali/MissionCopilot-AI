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
            == ["v1-store-info", "v2-missions", "v3-leases-and-shreds", "v4-evidence", "v5-facts", "v6-sentences",
                "v7-append-only", "v8-audit", "v9-pack-files", "v10-mission-lives", "v11-site-walk",
                "v12-action-photo", "v13-red-flags"])
    }

    @Test func aShredFromBeforeMissionLivesStaysAShredAfterTheUpgrade() throws {
        // #94: a phone shredded on build 2 keeps its record, now as the mission's first life.
        let file = path()
        let key = try DataKey.random()
        let old = try EncryptedStore.open(at: file, key: key, upTo: "v9-pack-files")
        try old.rawExecuteForTests("""
            INSERT INTO mission VALUES ('kandor-roads', 'Roads', 'official_use_only', x'00', x'00');
            INSERT INTO mission VALUES ('kandor-ports', 'Ports', 'official_use_only', x'00', x'00');
            INSERT INTO shred_record VALUES ('kandor-roads', 'shredOrder', 1000);
            """)

        let missions = MissionStore(store: try EncryptedStore.open(at: file, key: key), vault: SoftwareKeyVault())

        #expect(try missions.shredRecords().map(\.mission) == ["kandor-roads"])
        #expect(try missions.isShredded("kandor-roads"))
        #expect(try missions.isShredded("kandor-ports") == false)
    }
}
