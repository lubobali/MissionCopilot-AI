import Foundation
import GRDB
import Testing
@testable import EncryptionLab

/// Simulator form of the on-device outside check: read the raw files the way an attacker with a copy would.
struct OutsideCheckTests {
    private func rawBytes(ofDatabaseAt path: String) throws -> Data {
        // WAL mode: recent pages may still be in -wal, so read both files.
        try [path, path + "-wal"].filter { FileManager.default.fileExists(atPath: $0) }
            .reduce(into: Data()) { $0.append(try Data(contentsOf: URL(fileURLWithPath: $1))) }
    }

    private func writeMission(into pool: DatabasePool) throws {
        let store = try MissionStore(db: pool, vault: SoftwareKeyVault())
        try store.createMission(id: "kandor-roads", title: "Kandor rural roads")
    }

    private func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite").path
    }

    @Test func plainTwinShowsTheTitleInItsBytes() throws {
        let path = tempPath()
        try writeMission(into: EncryptedDatabase.openUnencrypted(at: path))

        #expect(try rawBytes(ofDatabaseAt: path).range(of: Data("Kandor".utf8)) != nil)
    }

    @Test func encryptedFileHidesTheTitle() throws {
        let path = tempPath()
        try writeMission(into: EncryptedDatabase.open(at: path, key: DatabaseKey.random()))

        #expect(try rawBytes(ofDatabaseAt: path).range(of: Data("Kandor".utf8)) == nil)
        #expect(try rawBytes(ofDatabaseAt: path).prefix(15) != Data("SQLite format 3".utf8))
    }
}
