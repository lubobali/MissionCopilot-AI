import Foundation
import Testing
@testable import MissionCopilot

struct ModelStoreTests {
    private func makeTempBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func modelsFolderIsCreatedAndExcludedFromBackup() throws {
        let base = try makeTempBase()
        let store = ModelStore(applicationSupport: base, inbox: base.appendingPathComponent("Inbox"))

        let folder = try store.prepareModelsFolder()

        #expect(FileManager.default.fileExists(atPath: folder.path))
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func importMovesModelFilesFromTheInbox() throws {
        let base = try makeTempBase()
        let inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: inbox.appendingPathComponent("model.gguf"))
        try Data("note".utf8).write(to: inbox.appendingPathComponent("readme.txt"))
        let store = ModelStore(applicationSupport: base, inbox: inbox)

        let imported = try store.importFromInbox()

        #expect(imported == ["model.gguf"])
        #expect(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("model.gguf").path) == false)
        #expect(try store.installedModels() == ["model.gguf"])
    }

    @Test func importMovesMLXModelFolders() throws {
        let base = try makeTempBase()
        let inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        let mlx = inbox.appendingPathComponent("LFM2.5-1.2B-Instruct-4bit", isDirectory: true)
        try FileManager.default.createDirectory(at: mlx, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: mlx.appendingPathComponent("config.json"))
        let store = ModelStore(applicationSupport: base, inbox: inbox)

        let imported = try store.importFromInbox()

        #expect(imported == ["LFM2.5-1.2B-Instruct-4bit"])
    }
}
