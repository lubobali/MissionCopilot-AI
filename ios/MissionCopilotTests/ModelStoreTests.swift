import CryptoKit
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

    // Model folders arrive with their OpenSSF Model Signing bundle next to them (threat model T46).
    // Fixtures: a fake model signed by the official tool with a throwaway test key.
    private func fixtures() throws -> URL {
        let folder = Bundle(for: StoreBundleToken.self).url(forResource: "Fixtures", withExtension: nil)
        return try #require(folder).appendingPathComponent("ModelSigning", isDirectory: true)
    }

    private func testKey() throws -> P256.Signing.PublicKey {
        let pem = try Data(contentsOf: try fixtures().appendingPathComponent("test-key.pub"))
        return try P256.Signing.PublicKey(pemRepresentation: try #require(String(bytes: pem, encoding: .utf8)))
    }

    /// An inbox holding the fixture model as `name`, with `bundle` as its signature (nil: unsigned).
    private func inbox(model name: String, bundle: String?) throws -> (ModelStore, URL) {
        let base = try makeTempBase()
        let inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try fixtures().appendingPathComponent("fixture-model"), to: inbox.appendingPathComponent(name)
        )
        if let bundle {
            try FileManager.default.copyItem(
                at: try fixtures().appendingPathComponent(bundle), to: inbox.appendingPathComponent("\(name).sig")
            )
        }
        return (ModelStore(applicationSupport: base, inbox: inbox, publicKey: try testKey()), inbox)
    }

    @Test func aSignedModelFolderIsImported() throws {
        let (store, inbox) = try inbox(model: "fixture-model", bundle: "good.sig")

        let result = try store.importFromInbox()

        #expect(result.imported == ["fixture-model"])
        #expect(result.refused.isEmpty)
        #expect(try store.installedModels() == ["fixture-model"])
        #expect(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("fixture-model").path) == false)
        #expect(try store.verifiedModel(named: "fixture-model").lastPathComponent == "fixture-model")
    }

    @Test func anUnsignedModelFolderIsRefusedAndLeftInTheInbox() throws {
        let (store, inbox) = try inbox(model: "fixture-model", bundle: nil)

        let result = try store.importFromInbox()

        #expect(result.imported.isEmpty)
        #expect(result.refused == ["fixture-model": .unsigned])
        #expect(try store.installedModels().isEmpty)
        #expect(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("fixture-model").path))
    }

    @Test func aModelWhoseSignatureFailsIsRefused() throws {
        let (store, _) = try inbox(model: "fixture-model", bundle: "forged-digest.sig")

        let result = try store.importFromInbox()

        #expect(result.refused == ["fixture-model": .signature(.badSignature)])
        #expect(try store.installedModels().isEmpty)
    }

    @Test func aGGUFFileIsNoLongerImported() throws {
        let base = try makeTempBase()
        let inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: inbox.appendingPathComponent("model.gguf"))
        let store = ModelStore(applicationSupport: base, inbox: inbox, publicKey: try testKey())

        let result = try store.importFromInbox()

        #expect(result.imported.isEmpty)
        #expect(result.refused == ["model.gguf": .unsigned])
    }

    @Test func anInstalledModelChangedAfterImportFailsTheCheckBeforeLoading() throws {
        let (store, _) = try inbox(model: "fixture-model", bundle: "good.sig")
        _ = try store.importFromInbox()
        let installed = try store.installedModels()
        let weights = try store.verifiedModel(named: installed[0]).appendingPathComponent("model.safetensors")
        try Data("swapped".utf8).write(to: weights)

        #expect(throws: ModelSignature.Failure.changedFile("model.safetensors")) {
            try store.verifiedModel(named: "fixture-model")
        }
    }

    @Test func thePinnedKeyIsTheRepositorysPublicKey() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let published = try String(
            contentsOf: repo.appendingPathComponent("docs/models/model-signing.pub.pem"), encoding: .utf8
        )
        let pinned = try P256.Signing.PublicKey(pemRepresentation: ModelSigningKey.pem)

        #expect(try P256.Signing.PublicKey(pemRepresentation: published).rawRepresentation == pinned.rawRepresentation)
    }
}

private final class StoreBundleToken {}
