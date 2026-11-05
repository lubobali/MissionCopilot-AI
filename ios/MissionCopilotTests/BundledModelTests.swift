import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// The model ships inside the app (#125): it is trusted only after its signature checks out, and a build
/// without it says so plainly. Fixtures: a fake model signed by the official tool with a throwaway key.
struct BundledModelTests {
    private func fixtures() throws -> URL {
        let folder = Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil)
        return try #require(folder).appendingPathComponent("ModelSigning", isDirectory: true)
    }

    private func testKey() throws -> P256.Signing.PublicKey {
        let pem = try Data(contentsOf: try fixtures().appendingPathComponent("test-key.pub"))
        return try P256.Signing.PublicKey(pemRepresentation: try #require(String(bytes: pem, encoding: .utf8)))
    }

    /// App resources shaped like a Staging or Release build: Models/<name>/ and Models/<name>.sig.
    private func resources(signature: String? = "good.sig") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let models = root.appendingPathComponent(BundledModel.folder, isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try fixtures().appendingPathComponent("fixture-model"),
                                         to: models.appendingPathComponent(BundledModel.name))
        if let signature {
            try FileManager.default.copyItem(at: try fixtures().appendingPathComponent(signature),
                                             to: models.appendingPathComponent("\(BundledModel.name).sig"))
        }
        return root
    }

    @Test func aSignedModelInsideTheAppIsVerified() async throws {
        let state = await BundledModel.check(resources: try resources(), publicKey: try testKey())

        #expect(state == .verified(files: 3))
    }

    @Test func aBuildWithoutTheModelSaysSo() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        #expect(await BundledModel.check(resources: empty, publicKey: try testKey()) == .notInThisBuild)
        #expect(await BundledModel.check(resources: nil, publicKey: try testKey()) == .notInThisBuild)
    }

    @Test func theTestAppItselfShipsNoModel() async {
        // Debug builds (the tests) never carry the 633 MB model: scripts/bundle_model.py skips them.
        #expect(await BundledModel.check(resources: Bundle.main.resourceURL) == .notInThisBuild)
    }

    @Test func aModelWithoutItsSignatureIsRefused() async throws {
        let state = await BundledModel.check(resources: try resources(signature: nil), publicKey: try testKey())

        #expect(state == .refused(.unsigned))
    }

    @Test func aChangedFileIsRefused() async throws {
        let root = try resources()
        let weights = BundledModel.modelFolder(in: root).appendingPathComponent("model.safetensors")
        try Data("not the signed weights".utf8).write(to: weights)

        let state = await BundledModel.check(resources: root, publicKey: try testKey())

        #expect(state == .refused(.signature(.changedFile("model.safetensors"))))
    }

    @Test func aFileTheSignatureDoesNotListIsRefused() async throws {
        // Why the build copies only the signed files: the Hub download's own cache would land here.
        let root = try resources()
        try Data("cache".utf8).write(to: BundledModel.modelFolder(in: root).appendingPathComponent(".gitattributes"))

        let state = await BundledModel.check(resources: root, publicKey: try testKey())

        #expect(state == .refused(.signature(.extraFile(".gitattributes"))))
    }

    @Test func byDefaultOnlyOurPinnedKeyIsTrusted() async throws {
        // The fixture is signed by a throwaway key, so the app's own key refuses it.
        let state = await BundledModel.check(resources: try resources())

        #expect(state == .refused(.signature(.badSignature)))
    }
}

private final class FixtureToken {}
