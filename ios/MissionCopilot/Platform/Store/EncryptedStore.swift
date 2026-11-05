import Foundation
import GRDB

/// One user's encrypted database (ADR 0008 layer B): SQLCipher in WAL mode, the key set on every
/// connection. Opening runs the migrations, which read the schema, so a wrong key fails at once.
/// GRDB stays inside this folder; the rest of the app (and the tests) use this type's own API.
struct EncryptedStore: Sendable {
    enum Failure: Error, Equatable {
        case wrongKey
        /// The phone locked or the app left the screen: nothing is read or written until it resumes.
        case suspended
    }

    /// Private: every read and write goes through `read` and `write`, so none skips the pause.
    private let pool: DatabasePool
    /// Opened to pause on StoreSuspension's signals.
    let isSuspendable: Bool
    private let readPause: ReadPause?

    /// - Parameter suspendable: pauses on StoreSuspension's signals (the app's store always is, #69).
    /// - Parameter upTo: tests only, the last migration to run, to build an older store and prove its upgrade.
    static func open(at file: URL, key: DataKey, suspendable: Bool = false,
                     upTo migration: String? = nil) throws -> EncryptedStore {
        var config = Configuration()
        config.observesSuspensionNotifications = suspendable
        config.prepareDatabase { database in
            try database.usePassphrase(key.rawKeyLiteral)
        }
        do {
            let pool = try DatabasePool(path: file.path, configuration: config)
            if let migration {
                try StoreSchema.migrator.migrate(pool, upTo: migration)
            } else {
                try StoreSchema.migrator.migrate(pool)
            }
            return EncryptedStore(pool: pool, isSuspendable: suspendable, readPause: suspendable ? ReadPause() : nil)
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

    /// Every read goes through here. GRDB pauses writes only, but a read still maps the -shm file, and
    /// while the phone is locked that file is unreadable: the app is killed (SIGBUS, found on the iPhone, #74).
    func read<T>(_ body: (Database) throws -> T) throws -> T {
        if readPause?.isPaused == true { throw Failure.suspended }
        return try pool.read(body)
    }

    func info(_ key: String) throws -> String? {
        try read { database in
            try String.fetchOne(database, sql: "SELECT value FROM store_info WHERE key = ?", arguments: [key])
        }
    }

    func appliedMigrations() throws -> [String] {
        try read { database in try StoreSchema.migrator.appliedMigrations(database) }
    }

    /// Tests only: raw SQL, to prove the database's own rules (a fact needs a source, records cannot be
    /// changed) hold even for a caller that skips the app's checks. The app never calls it.
    func rawExecuteForTests(_ sql: String) throws {
        try write { database in try database.execute(sql: sql) }
    }

    /// Read on a reader connection (not the writer): proves readers got the key too.
    func readerCipherVersion() throws -> String {
        try read { database in try String.fetchOne(database, sql: "PRAGMA cipher_version") ?? "" }
    }
}

/// Follows the same pause and resume signals GRDB follows for writes, so reads stop at the same moment.
private final class ReadPause: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var observers: [NSObjectProtocol] = []

    init() {
        observers = [(Database.suspendNotification, true), (Database.resumeNotification, false)].map { name, pause in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.set(pause)
            }
        }
    }

    var isPaused: Bool { lock.withLock { paused } }

    private func set(_ pause: Bool) { lock.withLock { paused = pause } }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
