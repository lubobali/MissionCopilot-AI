import CryptoKit
import Foundation
import GRDB

/// Missions and their notes inside one user's encrypted store (ADR 0008 layers B and C). Each mission's
/// key is stored only wrapped by the vault (the Secure Enclave in the app); every note is sealed with it
/// before it touches the database. Shredding destroys the wrapping key; purge then removes the rows.
struct MissionStore: Sendable {
    let store: EncryptedStore
    let vault: any MissionKeyVault
    /// Who the audit log names for changes made through this store (the officer's id with sign-in, Phase 8).
    var actor = "phone"

    /// A new mission gets a fresh key and starts its offline lease (ADR 0012).
    func create(mission: String, title: String, classification: Classification = .officialUseOnly,
                now: Date = Date()) throws {
        let wrapped = try vault.wrap(SymmetricKey(size: .bits256), for: mission)
        try store.write { database in
            try database.execute(sql: "INSERT INTO mission VALUES (?, ?, ?, ?, ?)", arguments: [
                mission, title, classification.rawValue, wrapped.encapsulatedKey, wrapped.ciphertext
            ])
            try database.execute(sql: "INSERT INTO mission_lease VALUES (?, ?, ?)",
                                 arguments: [mission, now.timeIntervalSince1970, KeyLease.defaultDays])
            try EncryptedStore.appendAudit(AuditEntry(action: .missionCreated, actor: actor, mission: mission,
                                                      target: nil, time: now), in: database)
        }
    }

    func addNote(_ text: String, to mission: String) throws {
        let sealed = try MissionData.seal(Data(text.utf8), with: missionKey(for: mission))
        try store.write { database in
            try database.execute(sql: "INSERT INTO note(mission_id, sealed) VALUES (?, ?)",
                                 arguments: [mission, sealed])
        }
    }

    struct NotText: Error {}

    func notes(in mission: String) throws -> [String] {
        let key = try missionKey(for: mission)
        return try sealedNotes(in: mission).map { sealed in
            guard let text = String(bytes: try MissionData.open(sealed, with: key), encoding: .utf8) else {
                throw NotText()
            }
            return text
        }
    }

    /// Crypto-shred: destroy the wrapping key. The rows stay until purge, and can no longer be read.
    func shred(mission: String) throws {
        try vault.destroy(mission: mission)
    }

    /// Removes a shredded mission's rows (ADR 0008 rule 7: key first, then the data).
    func purge(mission: String) throws {
        try store.write { database in
            try database.execute(sql: "DELETE FROM mission WHERE id = ?", arguments: [mission])  // notes cascade
            try EncryptedStore.appendAudit(AuditEntry(action: .missionPurged, actor: actor, mission: mission,
                                                      target: nil, time: Date()), in: database)
        }
    }

    /// The notes as stored: sealed bytes, for the proof that the text is not in the row.
    func sealedNotes(in mission: String) throws -> [Data] {
        try store.pool.read { database in
            try Data.fetchAll(database, sql: "SELECT sealed FROM note WHERE mission_id = ? ORDER BY id",
                              arguments: [mission])
        }
    }

    func missionIDs() throws -> [String] {
        try store.pool.read { database in try String.fetchAll(database, sql: "SELECT id FROM mission ORDER BY id") }
    }

    /// Throws MissionKeyNotFound for an unknown or shredded mission.
    func missionKey(for mission: String) throws -> SymmetricKey {
        let row = try store.pool.read { database in
            try Row.fetchOne(database, sql: "SELECT encapsulated_key, wrapped_key FROM mission WHERE id = ?",
                             arguments: [mission])
        }
        guard let row else { throw MissionKeyNotFound(mission: mission) }
        let wrapped = WrappedMissionKey(encapsulatedKey: row["encapsulated_key"], ciphertext: row["wrapped_key"])
        return try vault.unwrap(wrapped, for: mission)
    }
}
