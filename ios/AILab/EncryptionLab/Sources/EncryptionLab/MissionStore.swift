import CryptoKit
import Foundation
import GRDB

/// Missions and their notes inside one user's encrypted database (ADR 0008, layers B and C).
/// The mission key is stored only wrapped; each note is sealed with it before it touches the database.
public struct MissionStore: Sendable {
    let db: DatabasePool
    private let vault: any MissionKeyVault

    public init(db: DatabasePool, vault: any MissionKeyVault) throws {
        self.db = db
        self.vault = vault
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS mission(
                    id TEXT PRIMARY KEY, title TEXT NOT NULL,
                    encapsulated_key BLOB NOT NULL, wrapped_key BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS note(
                    id INTEGER PRIMARY KEY, mission_id TEXT NOT NULL REFERENCES mission(id),
                    sealed BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS shred_record(
                    mission_id TEXT PRIMARY KEY, reason TEXT NOT NULL, at REAL NOT NULL);
                """)
        }
    }

    public func createMission(id: String, title: String) throws {
        let wrapped = try vault.wrap(SymmetricKey(size: .bits256), for: id)
        try db.write { db in
            try db.execute(sql: "INSERT INTO mission VALUES (?, ?, ?, ?)",
                           arguments: [id, title, wrapped.encapsulatedKey, wrapped.ciphertext])
        }
    }

    public func addNote(_ text: String, to mission: String) throws {
        let sealed = try MissionData.seal(Data(text.utf8), with: missionKey(for: mission))
        try db.write { db in
            try db.execute(sql: "INSERT INTO note(mission_id, sealed) VALUES (?, ?)", arguments: [mission, sealed])
        }
    }

    public func notes(in mission: String) throws -> [String] {
        let key = try missionKey(for: mission)
        let sealed = try db.read { db in
            try Data.fetchAll(db, sql: "SELECT sealed FROM note WHERE mission_id = ? ORDER BY id", arguments: [mission])
        }
        return try sealed.map { String(decoding: try MissionData.open($0, with: key), as: UTF8.self) }
    }

    /// Crypto-shred: destroy the wrapping key. Rows stay until purge, and can no longer be read.
    public func shred(mission: String) throws {
        try vault.destroy(mission: mission)
    }

    /// Removes a shredded mission's rows (ADR 0008 rule 7: key first, then the data).
    public func purge(mission: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM note WHERE mission_id = ?", arguments: [mission])
            try db.execute(sql: "DELETE FROM mission WHERE id = ?", arguments: [mission])
        }
    }

    public func sealedNoteCount(in mission: String) throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM note WHERE mission_id = ?", arguments: [mission]) ?? 0
        }
    }

    public func missionIDs() throws -> [String] {
        try db.read { db in try String.fetchAll(db, sql: "SELECT id FROM mission ORDER BY id") }
    }

    private func missionKey(for mission: String) throws -> SymmetricKey {
        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT encapsulated_key, wrapped_key FROM mission WHERE id = ?",
                             arguments: [mission])
        }
        guard let row else { throw MissionKeyNotFound(mission: mission) }
        let wrapped = WrappedMissionKey(encapsulatedKey: row["encapsulated_key"], ciphertext: row["wrapped_key"])
        return try vault.unwrap(wrapped, for: mission)
    }
}
