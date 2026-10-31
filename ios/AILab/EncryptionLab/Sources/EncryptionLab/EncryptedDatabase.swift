import GRDB

/// Opens SQLCipher databases in WAL mode (DatabasePool). A wrong key fails at open time, not on the first read.
public enum EncryptedDatabase {
    public static func open(at path: String, key: DatabaseKey) throws -> DatabasePool {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.usePassphrase(key.rawKeyLiteral)
            // SQLCipher only checks the key when it reads a page, so read one now.
            try db.execute(sql: "SELECT count(*) FROM sqlite_master")
        }
        return try DatabasePool(path: path, configuration: config)
    }

    /// Empty when plain SQLite is linked instead of SQLCipher.
    public static func cipherVersion() throws -> String {
        try DatabaseQueue().read { db in
            try String.fetchOne(db, sql: "PRAGMA cipher_version") ?? ""
        }
    }
}
