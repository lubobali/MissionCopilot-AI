import CryptoKit
import Foundation
import GRDB

/// One file of a stored pack, without its content.
struct StoredPackFile: Sendable, Equatable {
    let path: String, mediaType: String, size: Int, sha256: String
}

/// A mission's pack as the store holds it: its lineage (the signed pack's id, version and manifest hash),
/// its dates, its files and the project it describes.
struct StoredPack: Sendable, Equatable {
    let packId: String, version: Int, manifestSHA256: String
    let createdAt: Date, expiresAt: Date, importedAt: Date
    let files: [StoredPackFile]
    let project: PackProject
    var checklist: ChecklistSummary?
}

/// Moves a verified pack from its download folder into the encrypted mission store (#92, threats T51 and
/// T55). Every staged file is checked again against its manifest entry and the sections against the
/// contract's schema; then one transaction creates the mission on its first pack, applies the version rule
/// again (another import may have come first), replaces the older pack, seals every file with the mission
/// key, records the accepted version and appends an audit event. Only after that commits is the download
/// folder deleted. A paused store (the phone locked) refuses and keeps the folder for the next try.
enum PackImport {
    static func run(_ ready: PackReady, title: String, into store: MissionStore, schema: PackSchema,
                    now: Date = Date()) throws(PackRefusal) -> StoredPack {
        let pack = ready.manifest
        var files: [String: Data] = [:]
        for entry in pack.files {
            guard let data = try? ready.staging.ready(entry) else { throw .wrongHash }
            try PackVerifier.check(entry, data: data)
            files[entry.path] = data
        }
        let project = try PackSections.check(files, schema: schema)
        do {
            let key = try missionKey(for: pack.missionId, title: title, in: store, now: now)
            try store.store.write { database in
                if try !exists(pack.missionId, in: database), let wrapped = key.newWrapped {
                    try store.insert(MissionStore.NewMission(id: pack.missionId, title: title,
                                                             classification: .officialUseOnly, wrapped: wrapped),
                                     now: now, in: database)
                }
                try write(Staged(ready: ready, files: files), key: key.key, actor: store.actor, now: now,
                          in: database)
            }
        } catch let refusal as PackRefusal {
            throw refusal
        } catch {
            throw .storeUnavailable
        }
        try? ready.staging.clear()  // a folder left behind is swept when the mission list opens (#92)
        return StoredPack(packId: pack.packId, version: pack.version, manifestSHA256: PackAcceptance.hash(
            ready.manifestBytes), createdAt: pack.createdAt, expiresAt: pack.expiresAt, importedAt: now,
            files: pack.files.map { StoredPackFile(path: $0.path, mediaType: $0.mediaType, size: $0.size,
                                                   sha256: $0.sha256) },
            project: project, checklist: files["forms/road-checklist.json"].flatMap { try? ChecklistForm.read($0) }
                .map(ChecklistSummary.init))
    }

    /// The mission's key, or a new one (and its wrapped form) for a mission the store does not have yet.
    private static func missionKey(for mission: String, title: String, in store: MissionStore,
                                   now: Date) throws -> (key: SymmetricKey, newWrapped: WrappedMissionKey?) {
        if try store.missionIDs().contains(mission) { return (try store.missionKey(for: mission), nil) }
        let key = SymmetricKey(size: .bits256)
        return (key, try store.vault.wrap(key, for: mission))
    }

    private static func exists(_ mission: String, in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: "SELECT EXISTS (SELECT 1 FROM mission WHERE id = ?)", arguments: [mission])
            ?? false
    }

    /// A verified pack and its files' bytes, each already checked against its entry.
    private struct Staged {
        let ready: PackReady, files: [String: Data]
    }

    private static func write(_ staged: Staged, key: SymmetricKey, actor: String, now: Date,
                              in database: Database) throws {
        let ready = staged.ready, files = staged.files
        let pack = ready.manifest, mission = pack.missionId, accepted = MissionStore.acceptedKey(mission)
        let last = MissionStore.acceptedPack(try String.fetchOne(
            database, sql: "SELECT value FROM store_info WHERE key = ?", arguments: [accepted]))
        try PackAcceptance.versionRule(pack, manifestBytes: ready.manifestBytes, last: last)
        let manifestSHA256 = PackAcceptance.hash(ready.manifestBytes)
        try database.execute(sql: "DELETE FROM mission_pack WHERE mission_id = ?", arguments: [mission])
        try database.execute(sql: "INSERT INTO mission_pack VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: [
            mission, pack.packId, pack.version, manifestSHA256, try MissionData.seal(ready.manifestBytes, with: key),
            pack.createdAt.timeIntervalSince1970, pack.expiresAt.timeIntervalSince1970, now.timeIntervalSince1970
        ])
        for entry in pack.files {
            try database.execute(sql: "INSERT INTO pack_file VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [
                mission, entry.path, entry.mediaType, entry.size, entry.sha256,
                Classification.officialUseOnly.rawValue, try MissionData.seal(files[entry.path] ?? Data(), with: key)
            ])
        }
        try database.execute(sql: "INSERT OR REPLACE INTO store_info VALUES (?, ?)",
                             arguments: [accepted, "\(pack.version) \(manifestSHA256)"])
        try EncryptedStore.appendAudit(AuditEntry(action: .packImported, actor: actor, mission: mission,
                                                  target: "v\(pack.version)", time: now), in: database)
    }
}
