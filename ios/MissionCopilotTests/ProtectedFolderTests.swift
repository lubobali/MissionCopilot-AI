import Foundation
import Testing
@testable import MissionCopilot

#if targetEnvironment(simulator)
private let onSimulator = true
#else
private let onSimulator = false
#endif

/// One folder per user for the encrypted database (ADR 0008 layer A, #69): file protection Complete
/// (unreadable while the phone is locked) and never in iCloud or computer backups.
struct ProtectedFolderTests {
    private func base() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func eachUserGetsTheirOwnFolder() throws {
        let folder = try ProtectedFolder.create(for: "officer-7", in: base())

        #expect(folder.lastPathComponent == "officer-7")
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func theFolderIsNeverBackedUp() throws {
        let folder = try ProtectedFolder.create(for: "officer-7", in: base())

        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    // The Simulator uses the Mac's disk and reports no protection (nil); the phone run (#74) proves it.
    @Test(.disabled(if: onSimulator, "No Data Protection on the Simulator; proven on the iPhone"))
    func theFolderIsLockedWhenThePhoneIsLocked() throws {
        let folder = try ProtectedFolder.create(for: "officer-7", in: base())

        #expect(try ProtectedFolder.protection(of: folder) == .complete)
    }

    @Test(arguments: ["", ".", "..", "../other", "a/b", "nul\u{0}name"])
    func aUserNameThatCouldLeaveTheFolderIsRefused(user: String) throws {
        let base = try base()

        #expect(throws: ProtectedFolder.UnsafeUserName(user: user)) {
            try ProtectedFolder.create(for: user, in: base)
        }
    }

    @Test func theReportListsTheDatabaseAndItsLogFiles() throws {
        let folder = try ProtectedFolder.create(for: "officer-7", in: base())
        // Kept open: closing the database cleans up its -wal and -shm files.
        let store = try EncryptedStore.open(at: folder.appendingPathComponent("store.sqlite"), key: DataKey.random())
        try store.setInfo("site", "Kandor")

        let names = try ProtectedFolder.report(folder).map(\.name)
        #expect(names == ["store.sqlite", "store.sqlite-shm", "store.sqlite-wal"])
    }
}
