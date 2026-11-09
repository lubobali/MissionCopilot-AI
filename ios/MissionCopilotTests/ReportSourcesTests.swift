import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// Report sources (#162, decided A): every source a report sentence can cite becomes evidence with facts, so
/// ADR 0009's one path (sentence -> facts -> evidence) covers the whole report. The pack keeps the server's
/// signature; the pack and the finished walk become evidence items; code writes facts from the pack's records,
/// the walk's answers and the red flags.
struct ReportSourcesTests {
    static let mission = PackDownloaderTests.mission

    // MARK: 7.1.1 the pack keeps the server's signature

    /// The downloader passes on the signature it checked, and the import keeps it with the manifest.
    @Test func theServersSignatureIsKeptWithThePack() async throws {
        let rig = try PackDownloaderTests.Rig()
        guard case .verified(let ready) = await rig.run() else { throw CancellationError() }

        #expect(ready.signature == FakePackServer.file("signature.json"))
        let store = try Self.emptyStore()
        _ = try PackImport.run(ready, title: "Kandor", into: store, schema: PackSectionsTests.schema())

        #expect(try store.packSignature(in: Self.mission) == FakePackServer.file("signature.json"))
    }

    /// A pack imported before #162 has no signature kept: nil, never an error.
    @Test func aPackWithoutAKeptSignatureGivesNil() async throws {
        let rig = try PackDownloaderTests.Rig()
        guard case .verified(var ready) = await rig.run() else { throw CancellationError() }
        ready.signature = nil
        let store = try Self.emptyStore()
        _ = try PackImport.run(ready, title: "Kandor", into: store, schema: PackSectionsTests.schema())

        #expect(try store.packSignature(in: Self.mission) == nil)
        #expect(try store.packSignature(in: "no-such-mission") == nil)
    }

    static func emptyStore() throws -> MissionStore {
        try MissionStore(store: EncryptedStore.open(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite"),
            key: DataKey.random()), vault: SoftwareKeyVault())
    }
}
