import Foundation
import Testing
@testable import EncryptionLab

#if targetEnvironment(simulator)
private let onSimulator = true
#else
private let onSimulator = false
#endif

struct ProtectedDirectoryTests {
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func eachUserGetsTheirOwnFolder() throws {
        let base = try makeBase()

        let folder = try ProtectedDirectory.create(for: "amina", in: base)

        #expect(folder.lastPathComponent == "amina")
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    // The Simulator uses the Mac's disk and reports no protection at all (nil); the AI Lab app proves it on the iPhone.
    @Test(.disabled(if: onSimulator, "No Data Protection on the Simulator, proven on device"))
    func folderIsLockedWhenThePhoneIsLocked() throws {
        let folder = try ProtectedDirectory.create(for: "amina", in: makeBase())

        #expect(try ProtectedDirectory.protection(of: folder) == .complete)
    }

    @Test func folderIsNotInBackups() throws {
        let folder = try ProtectedDirectory.create(for: "amina", in: makeBase())

        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test(arguments: ["", ".", "..", "../omar", "a/b"])
    func unsafeUserNamesAreRejected(user: String) throws {
        let base = try makeBase()

        #expect(throws: ProtectedDirectory.UnsafeUserName.self) {
            try ProtectedDirectory.create(for: user, in: base)
        }
    }

    @Test func reportListsTheDatabaseAndItsWALFiles() throws {
        let folder = try ProtectedDirectory.create(for: "amina", in: makeBase())
        let pool = try EncryptedDatabase.open(at: folder.appendingPathComponent("user.sqlite").path,
                                              key: DatabaseKey.random())
        try pool.write { db in try db.execute(sql: "CREATE TABLE note(text TEXT)") }

        let report = try ProtectedDirectory.report(folder)

        #expect(report.map(\.name) == ["user.sqlite", "user.sqlite-shm", "user.sqlite-wal"])
    }
}
