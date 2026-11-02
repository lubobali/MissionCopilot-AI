import Foundation
import Testing
@testable import MissionCopilot

/// Missions and their notes inside the user's encrypted store (ADR 0008 layers B and C, #70). Each
/// note is sealed with its mission's key before it touches the database; shredding destroys that key.
struct MissionStoreTests {
    private func missions() throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        return MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()), vault: SoftwareKeyVault())
    }

    @Test func aNoteReadsBackInItsMission() throws {
        let store = try missions()
        try store.create(mission: "kandor-roads", title: "Kandor rural roads")

        try store.addNote("Km 42 culvert washed out", to: "kandor-roads")
        try store.addNote("Bridge not started", to: "kandor-roads")

        #expect(try store.notes(in: "kandor-roads") == ["Km 42 culvert washed out", "Bridge not started"])
    }

    @Test func aNoteIsSealedInsideTheDatabaseToo() throws {
        let store = try missions()
        try store.create(mission: "kandor-roads", title: "Kandor rural roads")
        try store.addNote("Km 42 culvert washed out", to: "kandor-roads")

        // Layer C on top of SQLCipher: even with the database key, the text is not in the row.
        let sealed = try store.sealedNotes(in: "kandor-roads")
        #expect(sealed.count == 1 && sealed[0].range(of: Data("culvert".utf8)) == nil)
    }

    @Test func aShreddedMissionKeepsItsRowsButCannotBeRead() throws {
        let store = try missions()
        try store.create(mission: "kandor-roads", title: "Kandor rural roads")
        try store.addNote("Km 42 culvert washed out", to: "kandor-roads")

        try store.shred(mission: "kandor-roads")

        // The proof is the crypto, not a delete: the sealed row is still there, and unreadable.
        #expect(try store.sealedNotes(in: "kandor-roads").count == 1)
        #expect(throws: MissionKeyNotFound(mission: "kandor-roads")) { try store.notes(in: "kandor-roads") }
    }

    @Test func shreddingOneMissionLeavesTheOthersReadable() throws {
        let store = try missions()
        for mission in ["kandor-roads", "kandor-bridges"] {
            try store.create(mission: mission, title: mission)
            try store.addNote("note for \(mission)", to: mission)
        }

        try store.shred(mission: "kandor-roads")

        #expect(try store.notes(in: "kandor-bridges") == ["note for kandor-bridges"])
    }

    @Test func purgeRemovesAShreddedMissionsRows() throws {
        let store = try missions()
        try store.create(mission: "kandor-roads", title: "Kandor rural roads")
        try store.addNote("Km 42 culvert washed out", to: "kandor-roads")
        try store.shred(mission: "kandor-roads")

        try store.purge(mission: "kandor-roads")

        #expect(try store.sealedNotes(in: "kandor-roads").isEmpty)
        #expect(try store.missionIDs().isEmpty)
    }

    @Test func aNoteForAMissingMissionIsRefused() throws {
        #expect(throws: MissionKeyNotFound(mission: "nowhere")) { try missions().addNote("x", to: "nowhere") }
    }

    @Test func missionsAreListedInOrder() throws {
        let store = try missions()
        for mission in ["b", "a"] { try store.create(mission: mission, title: mission) }

        #expect(try store.missionIDs() == ["a", "b"])
    }
}
