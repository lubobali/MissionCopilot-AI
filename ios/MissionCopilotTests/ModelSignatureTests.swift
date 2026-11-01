import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// The phone checks a model folder against an OpenSSF Model Signing bundle before using it
/// (threat model T46). Fixtures are made by the official tool (scripts/make_model_signing_fixtures.py),
/// and the phone must agree with the official verifier's recorded verdict in every case.
struct ModelSignatureTests {
    private let fixtures: URL

    init() throws {
        let folder = Bundle(for: BundleToken.self).url(forResource: "Fixtures", withExtension: nil)
        fixtures = try #require(folder).appendingPathComponent("ModelSigning", isDirectory: true)
    }

    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: fixtures.appendingPathComponent(name))
    }

    private func key(_ name: String) throws -> P256.Signing.PublicKey {
        try P256.Signing.PublicKey(pemRepresentation: try #require(String(bytes: data(name), encoding: .utf8)))
    }

    /// A private copy of the fixture model to change.
    func modelCopy() throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("fixture-model"), to: copy)
        return copy
    }

    func verify(_ folder: URL, bundle: String = "good.sig", key: String = "test-key.pub") throws -> [String] {
        try ModelSignature.verify(modelFolder: folder, bundle: data(bundle), publicKey: self.key(key))
    }

    func failure(_ check: () throws -> [String]) -> ModelSignature.Failure? {
        do {
            _ = try check()
            return nil
        } catch {
            return error as? ModelSignature.Failure
        }
    }

    @Test func theOfficialToolsBundleVerifies() throws {
        let files = try verify(try modelCopy())

        #expect(files == ["config.json", "model.safetensors", "tokenizer.json"])
    }

    @Test func oneChangedByteIsCaught() throws {
        let model = try modelCopy()
        let weights = model.appendingPathComponent("model.safetensors")
        var bytes = try Data(contentsOf: weights)
        bytes[0] ^= 0xFF
        try bytes.write(to: weights)

        #expect(failure { try verify(model) } == .changedFile("model.safetensors"))
    }

    @Test func anExtraFileIsCaught() throws {
        let model = try modelCopy()
        try Data("print('hi')\n".utf8).write(to: model.appendingPathComponent("extra.py"))

        #expect(failure { try verify(model) } == .extraFile("extra.py"))
    }

    @Test func aMissingFileIsCaught() throws {
        let model = try modelCopy()
        try FileManager.default.removeItem(at: model.appendingPathComponent("tokenizer.json"))

        #expect(failure { try verify(model) } == .missingFile("tokenizer.json"))
    }

    @Test func aSymlinkIsRefused() throws {
        let model = try modelCopy()
        try FileManager.default.createSymbolicLink(
            at: model.appendingPathComponent("link.json"),
            withDestinationURL: model.appendingPathComponent("config.json")
        )

        #expect(failure { try verify(model) } == .symlink("link.json"))
    }

    @Test func anotherKeyIsRefused() throws {
        #expect(failure { try verify(try modelCopy(), key: "other-key.pub") } == .badSignature)
    }

    @Test func aDigestChangedWithoutResigningIsRefused() throws {
        #expect(failure { try verify(try modelCopy(), bundle: "forged-digest.sig") } == .badSignature)
    }

    @Test func aSignedEnvelopeOfTheWrongTypeIsRefused() throws {
        #expect(failure { try verify(try modelCopy(), bundle: "wrong-type.sig") } == .wrongPayloadType)
    }

    @Test func aSignedFileNameThatClimbsOutOfTheFolderIsRefused() throws {
        let refused = failure { try verify(try modelCopy(), bundle: "climbing-name.sig") }

        #expect(refused == .unsafeFileName("../outside.json"))
    }

    @Test func garbageIsNotABundle() throws {
        let check = { try ModelSignature.verify(
            modelFolder: try modelCopy(), bundle: Data("not json".utf8), publicKey: try key("test-key.pub")
        ) }

        #expect(failure(check) == .malformedBundle)
    }

    @Test func thePhoneAgreesWithTheOfficialVerifierInEveryCase() throws {
        let official = try JSONDecoder().decode([String: Bool].self, from: data("expected.json"))
        let cases: [String: () throws -> [String]] = [
            "good": { try verify(try modelCopy()) },
            "other key": { try verify(try modelCopy(), key: "other-key.pub") },
            "one byte changed": {
                let model = try modelCopy()
                let weights = model.appendingPathComponent("model.safetensors")
                try (Data("X".utf8) + (try Data(contentsOf: weights)).dropFirst()).write(to: weights)
                return try verify(model)
            },
            "extra file": {
                let model = try modelCopy()
                try Data("print('hi')\n".utf8).write(to: model.appendingPathComponent("extra.py"))
                return try verify(model)
            },
            "missing file": {
                let model = try modelCopy()
                try FileManager.default.removeItem(at: model.appendingPathComponent("tokenizer.json"))
                return try verify(model)
            }
        ]

        #expect(Set(cases.keys) == Set(official.keys))
        for (name, check) in cases {
            #expect((failure(check) == nil) == official[name], "\(name)")
        }
    }
}

private final class BundleToken {}

extension ModelSignatureTests {
    @Test func aSignedStatementWhoseSummaryDoesNotMatchItsFilesIsRefused() throws {
        #expect(failure { try verify(try modelCopy(), bundle: "wrong-subject.sig") } == .wrongStatement)
    }
}
