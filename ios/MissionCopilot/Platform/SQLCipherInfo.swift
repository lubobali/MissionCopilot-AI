import Foundation
import GRDB

/// Which SQLite the app runs on (ADR 0008 layer B). It must be SQLCipher, linked once, inside the app.
enum SQLCipherInfo {
    /// "4.20.0 community" for SQLCipher; nil would mean plain SQLite, which cannot encrypt.
    static func version() throws -> String? {
        try DatabaseQueue().read { database in try String.fetchOne(database, sql: "PRAGMA cipher_version") }
    }
}
