import CryptoKit
import Foundation
import Testing
import UIKit
@testable import MissionCopilot

/// A verified pack goes into the encrypted mission store (#92, threats T51 and T55): every file sealed with
/// the mission key and kept with its lineage (pack id, version, the manifest's and the file's SHA-256),
/// all in one transaction with the version it accepts and an audit event; then the download folder is
/// deleted. Nothing is written for a pack that fails a check, and nothing while the store is paused.
@Suite(.timeLimit(.minutes(1)))
struct PackImportTests {
    static let mission = PackDownloaderTests.mission
    static let title = "Kandor Rural Roads Project, Package 1"

    /// The real Kandor pack, downloaded and verified into a staging folder.
    private func downloaded() async throws -> (PackDownloaderTests.Rig, PackReady) {
        let rig = try PackDownloaderTests.Rig()
        guard case .verified(let ready) = await rig.run() else { throw CancellationError() }
        return (rig, ready)
    }

    private func run(_ ready: PackReady, into store: MissionStore, now: Date = Date()) throws(PackRefusal)
        -> StoredPack {
        // swiftlint:disable:next force_try
        try PackImport.run(ready, title: Self.title, into: store, schema: try! PackSectionsTests.schema(), now: now)
    }

    /// The same files under another manifest: the version and the file list changed, as a new publish,
    /// in a download folder of their own (an import deletes the one it came from).
    private func republished(_ ready: PackReady, version: Int, dropping path: String? = nil) throws -> PackReady {
        let staging = try PackStaging(base: FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString), mission: ready.manifest.missionId)
        for file in ready.manifest.files {
            try staging.append(FakePackServer.file("files/\(file.sha256)"), to: file)
            try staging.finish(file)
        }
        let old = ready.manifest
        let manifest = PackManifest(packId: UUID().uuidString.lowercased(), orgId: old.orgId, missionId: old.missionId,
                                    version: version, createdAt: old.createdAt, expiresAt: old.expiresAt,
                                    minAppVersion: old.minAppVersion, keyId: old.keyId,
                                    files: old.files.filter { $0.path != path })
        return PackReady(manifest: manifest, manifestBytes: Data("manifest v\(version)".utf8), staging: staging)
    }

    private func rowCount(_ store: MissionStore, _ table: String) throws -> Int {
        try store.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)") ?? -1 }
    }

    // Into the store

    @Test(.needsRepoFiles) func everyFileIsInTheStoreExactlyAsSignedAndTheDownloadFolderIsGone() async throws {
        let (rig, ready) = try await downloaded()

        let stored = try run(ready, into: rig.store)

        #expect(stored.files.count == 12)
        for file in ready.manifest.files {
            #expect(try rig.store.packFile(file.path, in: Self.mission) == FakePackServer.file("files/\(file.sha256)"))
        }
        #expect(!FileManager.default.fileExists(atPath: ready.staging.folder.path()))
    }

    @Test(.needsRepoFiles) func theFilesAreSealedWithTheMissionKeyNotStoredAsText() async throws {
        let (rig, ready) = try await downloaded()
        _ = try run(ready, into: rig.store)

        let sealed = try rig.store.store.read { try Data.fetchAll($0, sql: "SELECT sealed FROM pack_file") }

        #expect(sealed.count == 12)
        #expect(sealed.allSatisfy { $0.range(of: Data("Kandor Ministry of Public Works".utf8)) == nil })
        let labels = try rig.store.store.read { try String.fetchAll($0, sql: "SELECT classification FROM pack_file") }
        #expect(Set(labels) == [Classification.officialUseOnly.rawValue])  // the data map's label
    }

    @Test(.needsRepoFiles) func eachFileKeepsItsLineageToTheSignedPack() async throws {
        let (rig, ready) = try await downloaded()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try run(ready, into: rig.store, now: now)

        let stored = try #require(try rig.store.storedPack(for: Self.mission))
        #expect(stored.packId == ready.manifest.packId && stored.version == 1)
        #expect(stored.manifestSHA256 == PackVerifier.hex(SHA256.hash(data: ready.manifestBytes)))
        #expect(stored.createdAt == ready.manifest.createdAt && stored.expiresAt == ready.manifest.expiresAt)
        #expect(stored.importedAt == now && stored.project.title == Self.title)
        #expect(stored.files.map(\.sha256).sorted() == ready.manifest.files.map(\.sha256).sorted())
    }

    @Test(.needsRepoFiles) func theFirstPackCreatesTheMissionAndRecordsWhatWasAccepted() async throws {
        let (rig, ready) = try await downloaded()

        _ = try run(ready, into: rig.store)

        #expect(try rig.store.missionIDs() == [Self.mission])
        let title = try rig.store.store.read { try String.fetchOne($0, sql: "SELECT title FROM mission") }
        #expect(title == Self.title)
        #expect(try rig.store.lastAcceptedPack(for: Self.mission)?.version == 1)
        let events = try rig.store.store.auditEvents()
        #expect(events.map(\.action) == [.missionCreated, .packImported])
        #expect(events.last?.target == "v1")
        #expect(try rig.store.store.verifyAudit() == .valid(count: 2))
    }

    // A newer pack, an older one

    @Test(.needsRepoFiles) func aNewerPackReplacesTheOlderAndKeepsTheMissionsKey() async throws {
        let (rig, ready) = try await downloaded()
        _ = try run(ready, into: rig.store)
        try rig.store.addNote("before the new pack", to: Self.mission)

        let newer = try run(try republished(ready, version: 2, dropping: "documents/aide-memoire-2026-05.md"),
                            into: rig.store)

        #expect(newer.version == 2 && newer.files.count == 11)
        #expect(try rowCount(rig.store, "pack_file") == 11 && rowCount(rig.store, "mission_pack") == 1)
        #expect(try rig.store.notes(in: Self.mission) == ["before the new pack"])
        #expect(throws: (any Error).self) {
            try rig.store.packFile("documents/aide-memoire-2026-05.md", in: Self.mission)
        }
    }

    @Test(.needsRepoFiles) func anOlderPackThanTheLastAcceptedIsRefusedInsideTheImportToo() async throws {
        let (rig, ready) = try await downloaded()
        try rig.store.recordAcceptedPack(AcceptedPack(version: 3, manifestSHA256: "x"), for: Self.mission)

        #expect(throws: PackRefusal.older) { try run(ready, into: rig.store) }
        #expect(try rowCount(rig.store, "mission") == 0 && rowCount(rig.store, "pack_file") == 0)
        #expect(FileManager.default.fileExists(atPath: ready.staging.folder.path()))
    }

    // Nothing written for a pack that fails a check

    @Test(.needsRepoFiles) func aPackMissingASectionIsRefusedAndNothingIsWritten() async throws {
        let (rig, ready) = try await downloaded()

        #expect(throws: PackRefusal.badSection) {
            try run(try republished(ready, version: 1, dropping: "sections/ratings.json"), into: rig.store)
        }
        #expect(try rowCount(rig.store, "mission") == 0 && rowCount(rig.store, "audit_event") == 0)
    }

    @Test(.needsRepoFiles) func aStagedFileChangedOnDiskAfterTheDownloadIsRefused() async throws {
        let (rig, ready) = try await downloaded()
        let file = try #require(ready.manifest.files.first)
        let url = ready.staging.folder.appending(path: file.sha256)
        var bytes = try Data(contentsOf: url)
        bytes[0] ^= 0x01
        try bytes.write(to: url)

        #expect(throws: PackRefusal.wrongHash) { try run(ready, into: rig.store) }
        #expect(try rowCount(rig.store, "pack_file") == 0)
    }

    @Test(.needsRepoFiles) func whileTheStoreIsPausedNothingIsWrittenAndTheDownloadIsKept() async throws {
        let (rig, ready) = try await downloaded()
        let paused = MissionStore(store: try EncryptedStore.open(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite"),
            key: DataKey.random(), suspendable: true), vault: SoftwareKeyVault())
        let center = NotificationCenter()
        let suspension = StoreSuspension(observing: center)
        center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)

        #expect(throws: PackRefusal.storeUnavailable) { try run(ready, into: paused) }
        #expect(FileManager.default.fileExists(atPath: ready.staging.folder.path()))
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        #expect(try rowCount(paused, "mission") == 0)
        _ = (suspension, rig)
    }

    // The end of a mission

    @Test(.needsRepoFiles) func aShredMakesThePackUnreadableAndPurgeRemovesIt() async throws {
        let (rig, ready) = try await downloaded()
        _ = try run(ready, into: rig.store)

        try rig.store.shred(mission: Self.mission)
        #expect(throws: (any Error).self) { try rig.store.packFile("sections/project.json", in: Self.mission) }
        try rig.store.purge(mission: Self.mission)

        #expect(try rowCount(rig.store, "pack_file") == 0 && rowCount(rig.store, "mission_pack") == 0)
    }
}
