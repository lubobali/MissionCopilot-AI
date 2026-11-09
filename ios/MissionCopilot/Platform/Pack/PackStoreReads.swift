import Foundation
import GRDB

/// Reading a mission's pack back from the encrypted store (#92). File bytes are opened with the mission
/// key, so after a shred nothing of the pack can be read.
extension MissionStore {
    struct PackFileNotFound: Error {}

    /// The mission's pack, or nil when none was imported.
    /// The server's signature document kept with the mission's pack (#162); nil for a pack imported before it
    /// was kept, or no pack.
    func packSignature(in mission: String) throws -> Data? {
        let sealed = try store.read { database in
            try Data.fetchOne(database, sql: "SELECT sealed_signature FROM mission_pack WHERE mission_id = ?",
                              arguments: [mission])
        }
        guard let sealed else { return nil }
        return try MissionData.open(sealed, with: missionKey(for: mission))
    }

    func storedPack(for mission: String) throws -> StoredPack? {
        let rows = try store.read { database in
            (try Row.fetchOne(database, sql: "SELECT * FROM mission_pack WHERE mission_id = ?", arguments: [mission]),
             try Row.fetchAll(database, sql: "SELECT path, media_type, size, sha256 FROM pack_file"
                                + " WHERE mission_id = ? ORDER BY path", arguments: [mission]))
        }
        guard let pack = rows.0 else { return nil }
        let project = try JSONDecoder().decode(PackProject.self, from: packFile("sections/project.json", in: mission))
        return StoredPack(
            packId: pack["pack_id"], version: pack["version"], manifestSHA256: pack["manifest_sha256"],
            createdAt: Date(timeIntervalSince1970: pack["created_at"]),
            expiresAt: Date(timeIntervalSince1970: pack["expires_at"]),
            importedAt: Date(timeIntervalSince1970: pack["imported_at"]),
            files: rows.1.map { StoredPackFile(path: $0["path"], mediaType: $0["media_type"], size: $0["size"],
                                               sha256: $0["sha256"]) },
            project: project,
            checklist: (try? ChecklistForm.read(packFile("forms/road-checklist.json", in: mission)))
                .map(ChecklistSummary.init))
    }

    /// The bytes of the stored file with this SHA-256 (any path), or nil: a newer pack takes an unchanged
    /// file from here instead of fetching it again (#94). The caller checks it against its manifest entry.
    func packFile(sha256: String, in mission: String) throws -> Data? {
        let path = try store.read { database in
            try String.fetchOne(database, sql: "SELECT path FROM pack_file WHERE mission_id = ? AND sha256 = ?",
                                arguments: [mission, sha256])
        }
        return try path.map { try packFile($0, in: mission) }
    }

    /// Every file of the mission's pack by its path, opened with the mission key unwrapped once (#150: one
    /// Secure Enclave operation, not one per file; found on the iPhone, Ask was slow to open).
    func packFiles(in mission: String) throws -> [String: Data] {
        let rows = try store.read { database in
            try Row.fetchAll(database, sql: "SELECT path, sealed FROM pack_file WHERE mission_id = ?",
                             arguments: [mission])
        }
        guard !rows.isEmpty else { return [:] }
        let key = try missionKey(for: mission)
        var files: [String: Data] = [:]
        for row in rows {
            let path: String = row["path"]
            files[path] = try MissionData.open(row["sealed"], with: key)
        }
        return files
    }

    /// One file of the mission's pack, exactly as signed.
    func packFile(_ path: String, in mission: String) throws -> Data {
        let sealed = try store.read { database in
            try Data.fetchOne(database, sql: "SELECT sealed FROM pack_file WHERE mission_id = ? AND path = ?",
                              arguments: [mission, path])
        }
        guard let sealed else { throw PackFileNotFound() }
        return try MissionData.open(sealed, with: missionKey(for: mission))
    }
}
