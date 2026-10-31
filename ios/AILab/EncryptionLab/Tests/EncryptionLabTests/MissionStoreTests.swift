import Foundation
import GRDB
import Testing
@testable import EncryptionLab

struct MissionStoreTests {
    private func makeStore() throws -> (MissionStore, DatabasePool) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite").path
        let pool = try EncryptedDatabase.open(at: path, key: DatabaseKey.random())
        return (try MissionStore(db: pool, vault: SoftwareKeyVault()), pool)
    }

    @Test func noteReadsBackInItsMission() throws {
        let (store, _) = try makeStore()
        try store.createMission(id: "kandor-roads", title: "Kandor rural roads")

        try store.addNote("Km 42 culvert washed out", to: "kandor-roads")

        #expect(try store.notes(in: "kandor-roads") == ["Km 42 culvert washed out"])
    }

    @Test func noteIsSealedInsideTheDatabase() throws {
        let (store, pool) = try makeStore()
        try store.createMission(id: "kandor-roads", title: "Kandor rural roads")
        try store.addNote("Km 42 culvert washed out", to: "kandor-roads")

        let stored = try pool.read { db in try Data.fetchOne(db, sql: "SELECT sealed FROM note") }

        // Layer C on top of SQLCipher: even with the database key, the note text is not there.
        #expect(stored?.range(of: Data("culvert".utf8)) == nil)
    }

    @Test func shreddedMissionKeepsItsRowsButCannotBeRead() throws {
        let (store, _) = try makeStore()
        try store.createMission(id: "kandor-roads", title: "Kandor rural roads")
        try store.addNote("Km 42 culvert washed out", to: "kandor-roads")

        try store.shred(mission: "kandor-roads")

        // The proof is the crypto, not a delete: the sealed rows are still there, and unreadable.
        #expect(try store.sealedNoteCount(in: "kandor-roads") == 1)
        #expect(throws: MissionKeyNotFound(mission: "kandor-roads")) {
            try store.notes(in: "kandor-roads")
        }
    }

    @Test func shreddingOneMissionLeavesTheOtherReadable() throws {
        let (store, _) = try makeStore()
        try store.createMission(id: "kandor-roads", title: "Kandor rural roads")
        try store.createMission(id: "kandor-bridges", title: "Kandor bridges")
        try store.addNote("Bridge 3 deck cracked", to: "kandor-bridges")

        try store.shred(mission: "kandor-roads")

        #expect(try store.notes(in: "kandor-bridges") == ["Bridge 3 deck cracked"])
    }

    @Test func purgeRemovesTheShreddedRows() throws {
        let (store, _) = try makeStore()
        try store.createMission(id: "kandor-roads", title: "Kandor rural roads")
        try store.addNote("Km 42 culvert washed out", to: "kandor-roads")
        try store.shred(mission: "kandor-roads")

        try store.purge(mission: "kandor-roads")

        #expect(try store.sealedNoteCount(in: "kandor-roads") == 0)
        #expect(try store.missionIDs().isEmpty)
    }
}
