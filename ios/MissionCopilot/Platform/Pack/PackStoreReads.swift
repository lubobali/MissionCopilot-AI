import Foundation
import GRDB

/// Reading a mission's pack back from the encrypted store (#92). File bytes are opened with the mission
/// key, so after a shred nothing of the pack can be read.
extension MissionStore {
    struct PackFileNotFound: Error {}

    /// The mission's pack, or nil when none was imported.
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
            project: project)
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
