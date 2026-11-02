import Foundation
import GRDB

/// One user's encrypted database (ADR 0008 layer B): SQLCipher in WAL mode, the key set on every
/// connection. Opening runs the migrations, which read the schema, so a wrong key fails at once.
/// GRDB stays inside this folder; the rest of the app (and the tests) use this type's own API.
struct EncryptedStore: Sendable {
    enum Failure: Error, Equatable {
        case wrongKey
        /// The phone locked or the app left the screen: nothing is written until it resumes.
        case suspended
    }

    /// Used only inside Platform/Store, which keeps GRDB away from the rest of the app.
    let pool: DatabasePool
    /// Opened to pause on StoreSuspension's signals.
    let isSuspendable: Bool

    /// - Parameter suspendable: pauses on StoreSuspension's signals (the app's store always is, #69).
    static func open(at file: URL, key: DataKey, suspendable: Bool = false) throws -> EncryptedStore {
        var config = Configuration()
        config.observesSuspensionNotifications = suspendable
        config.prepareDatabase { database in
            try database.usePassphrase(key.rawKeyLiteral)
        }
        do {
            let pool = try DatabasePool(path: file.path, configuration: config)
            try StoreSchema.migrator.migrate(pool)
            return EncryptedStore(pool: pool, isSuspendable: suspendable)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            throw Failure.wrongKey
        }
    }

    func setInfo(_ key: String, _ value: String) throws {
        try write { database in
            try database.execute(sql: "INSERT OR REPLACE INTO store_info VALUES (?, ?)", arguments: [key, value])
        }
    }

    /// Every write goes through here, so a paused store answers `.suspended`, never a SQLite code.
    func write<T>(_ body: (Database) throws -> T) throws -> T {
        do {
            return try pool.write(body)
        } catch let error as DatabaseError where [.SQLITE_INTERRUPT, .SQLITE_ABORT].contains(error.resultCode) {
            throw Failure.suspended
        }
    }

    func info(_ key: String) throws -> String? {
        try pool.read { database in
            try String.fetchOne(database, sql: "SELECT value FROM store_info WHERE key = ?", arguments: [key])
        }
    }

    func appliedMigrations() throws -> [String] {
        try pool.read { database in try StoreSchema.migrator.appliedMigrations(database) }
    }

    /// Tests only: raw SQL, to prove the database's own rules (a fact needs a source, records cannot be
    /// changed) hold even for a caller that skips the app's checks. The app never calls it.
    func rawExecuteForTests(_ sql: String) throws {
        try write { database in try database.execute(sql: sql) }
    }

    /// Read on a reader connection (not the writer): proves readers got the key too.
    func readerCipherVersion() throws -> String {
        try pool.read { database in try String.fetchOne(database, sql: "PRAGMA cipher_version") ?? "" }
    }
}
