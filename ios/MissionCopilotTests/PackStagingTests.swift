import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// Where a pack waits while it downloads (#91): one folder per mission, never backed up, files that can
/// still be written after the phone locks (a download can go on in the background), each named by its
/// SHA-256 so a name can never climb out of the folder. A half-done file keeps its bytes across launches
/// for the next range request; a finished file is only kept if it is exactly what its manifest says.
struct PackStagingTests {
    static let mission = "6f1d2c3a-0000-4000-8000-000000000001"

    private func staging() throws -> PackStaging {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try PackStaging(base: base, mission: Self.mission)
    }

    private func entry(_ data: Data) -> PackFileEntry {
        PackFileEntry(path: "sections/project.json", sha256: PackVerifier.hex(SHA256.hash(data: data)),
                      size: data.count, mediaType: "application/json")
    }

    @Test func aMissionsFolderIsNeverBackedUp() throws {
        let staging = try staging()

        let values = try staging.folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(staging.folder.lastPathComponent == Self.mission)
    }

    @Test func aHalfDoneFileKeepsItsBytesForTheNextRange() throws {
        let staging = try staging()
        let data = Data("Kandor Rural Roads, Package 1".utf8)
        let file = entry(data)

        try staging.append(data.prefix(10), to: file)
        #expect(try staging.partialSize(of: file) == 10)
        try staging.append(data.dropFirst(10), to: file)

        #expect(try staging.partialSize(of: file) == data.count)
        #expect(try staging.partial(of: file) == data)
    }

    @Test func aFinishedFileIsKeptOnlyIfItMatchesItsEntry() throws {
        let staging = try staging()
        let data = Data("Kandor".utf8)
        let file = entry(data)
        try staging.append(data, to: file)

        try staging.finish(file)

        #expect(staging.isReady(file))
        #expect(try staging.ready(file) == data)
        #expect(try staging.partialSize(of: file) == 0)
    }

    @Test func aFinishedFileThatDoesNotMatchIsDeletedAndRefused() throws {
        let staging = try staging()
        let file = entry(Data("Kandor".utf8))
        try staging.append(Data("Kandar".utf8), to: file)

        #expect(throws: PackRefusal.wrongHash) { try staging.finish(file) }
        #expect(!staging.isReady(file))
        #expect(try staging.partialSize(of: file) == 0)
    }

    @Test func aReadyFileChangedOnDiskIsNoLongerReady() throws {
        let staging = try staging()
        let data = Data("Kandor".utf8)
        let file = entry(data)
        try staging.append(data, to: file)
        try staging.finish(file)

        try Data("Kandar".utf8).write(to: staging.folder.appending(path: file.sha256))

        #expect(!staging.isReady(file))
    }

    @Test func startingAFileOverDropsItsHalfDoneBytes() throws {
        let staging = try staging()
        let file = entry(Data("Kandor".utf8))
        try staging.append(Data("Kan".utf8), to: file)

        try staging.restart(file)

        #expect(try staging.partialSize(of: file) == 0)
    }

    @Test func clearingRemovesEverythingOfTheMission() throws {
        let staging = try staging()
        let file = entry(Data("Kandor".utf8))
        try staging.append(Data("Kandor".utf8), to: file)

        try staging.clear()

        #expect(!FileManager.default.fileExists(atPath: staging.folder.path()))
    }

    @Test(arguments: ["../x", "a/b", "", "6F1D2C3A-0000-4000-8000-000000000001"])
    func aMissionIdThatIsNotAPlainUUIDIsRefused(mission: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        #expect(throws: PackRefusal.wrongMission) { try PackStaging(base: base, mission: mission) }
    }
}
