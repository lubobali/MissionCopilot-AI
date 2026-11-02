import Foundation
import GRDB

/// One user's encrypted database (ADR 0008 layer B): SQLCipher in WAL mode, the key set on every
/// connection. Opening runs the migrations, which read the schema, so a wrong key fails at once.
/// GRDB stays inside this folder; the rest of the app (and the tests) use this type's own API.
struct EncryptedStore: Sendable {
    enum Failure: Error, Equatable { case wrongKey }

    private let pool: DatabasePool

    static func open(at file: URL, key: DataKey) throws -> EncryptedStore {
        var config = Configuration()
        config.prepareDatabase { database in
            try database.usePassphrase(key.rawKeyLiteral)
        }
        do {
            let pool = try DatabasePool(path: file.path, configuration: config)
            try migrator.migrate(pool)
            return EncryptedStore(pool: pool)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            throw Failure.wrongKey
        }
    }

    /// Each schema change is a new, named step; steps already applied are never run again.
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-store-info") { database in
            try database.create(table: "store_info") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
        }
        return migrator
    }

    func setInfo(_ key: String, _ value: String) throws {
        try pool.write { database in
            try database.execute(sql: "INSERT OR REPLACE INTO store_info VALUES (?, ?)", arguments: [key, value])
        }
    }

    func info(_ key: String) throws -> String? {
        try pool.read { database in
            try String.fetchOne(database, sql: "SELECT value FROM store_info WHERE key = ?", arguments: [key])
        }
    }

    func appliedMigrations() throws -> [String] {
        try pool.read { database in try Self.migrator.appliedMigrations(database) }
    }

    /// Read on a reader connection (not the writer): proves readers got the key too.
    func readerCipherVersion() throws -> String {
        try pool.read { database in try String.fetchOne(database, sql: "PRAGMA cipher_version") ?? "" }
    }
}
