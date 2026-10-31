import Foundation
import GRDB
import Testing
@testable import EncryptionLab

struct EncryptedDatabaseTests {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite").path
    }

    @Test func linksSQLCipherNotPlainSQLite() throws {
        // If plain SQLite were linked instead, cipher_version would be missing and nothing would be encrypted.
        let version = try EncryptedDatabase.cipherVersion()
        #expect(version.hasPrefix("4."))
    }

    @Test func rightKeyReadsBackTheData() throws {
        let path = tempPath()
        let key = DatabaseKey.random()
        try EncryptedDatabase.open(at: path, key: key).write { db in
            try db.execute(sql: "CREATE TABLE note(text TEXT); INSERT INTO note VALUES ('Kandor km 42')")
        }

        let text = try EncryptedDatabase.open(at: path, key: key).read { db in
            try String.fetchOne(db, sql: "SELECT text FROM note")
        }

        #expect(text == "Kandor km 42")
    }

    @Test func wrongKeyIsRejected() throws {
        let path = tempPath()
        try EncryptedDatabase.open(at: path, key: DatabaseKey.random()).write { db in
            try db.execute(sql: "CREATE TABLE note(text TEXT)")
        }

        #expect(throws: DatabaseError.self) {
            try EncryptedDatabase.open(at: path, key: DatabaseKey.random())
        }
    }

    @Test func keyIs32RandomBytes() {
        let first = DatabaseKey.random()
        let second = DatabaseKey.random()

        #expect(first.bytes.count == 32)
        #expect(first.bytes != second.bytes)
    }
}
