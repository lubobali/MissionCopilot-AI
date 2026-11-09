import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import MissionCopilot

/// Ask opens at once (#150, step 6.8.1b). Found on the iPhone (Lubo: "for the first 3 sec it looks like it
/// does not work"): opening the chat read every pack file on the main thread, and each file unwrapped the
/// mission key again through the Secure Enclave. Now the pack's files are read with one unwrap, the records
/// are read off the main thread, and the screen shows a spinner meanwhile.
struct AskOpeningTests {
    /// A vault that counts its unwraps (each one is a Secure Enclave operation on the iPhone).
    final class CountingVault: MissionKeyVault {
        let inner = SoftwareKeyVault()
        let unwraps = Mutex(0)

        func wrap(_ missionKey: SymmetricKey, for mission: String) throws -> WrappedMissionKey {
            try inner.wrap(missionKey, for: mission)
        }

        func unwrap(_ wrapped: WrappedMissionKey, for mission: String) throws -> SymmetricKey {
            unwraps.withLock { $0 += 1 }
            return try inner.unwrap(wrapped, for: mission)
        }

        func destroy(mission: String) throws { try inner.destroy(mission: mission) }

        var count: Int { unwraps.withLock { $0 } }
        func reset() { unwraps.withLock { $0 = 0 } }
    }

    /// The Kandor pack imported, a walk answer and a confirmed fact, with a counting vault.
    static func store() async throws -> (MissionStore, CountingVault) {
        let rig = try PackDownloaderTests.Rig()
        guard case .verified(let ready) = await rig.run() else { throw CancellationError() }
        let vault = CountingVault()
        let store = try MissionStore(store: EncryptedStore.open(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite"),
            key: DataKey.random()), vault: vault)
        let mission = PackDownloaderTests.mission
        _ = try PackImport.run(ready, title: "Kandor Rural Roads Project, Package 1", into: store,
                               schema: PackSectionsTests.schema())
        try store.saveAnswer("no", to: "bridge_started", form: SiteWalkStoreTests.form, mission: mission)
        return (store, vault)
    }

    @Test func thePacksFilesAreReadWithOneUnwrap() async throws {
        let (store, vault) = try await Self.store()
        let pack = try #require(try store.storedPack(for: PackDownloaderTests.mission))
        vault.reset()

        let files = try store.packFiles(in: PackDownloaderTests.mission)

        #expect(vault.count == 1)
        #expect(Set(files.keys) == Set(pack.files.map(\.path)))
        for file in pack.files.prefix(3) {
            #expect(files[file.path] == (try store.packFile(file.path, in: PackDownloaderTests.mission)))
        }
    }

    /// Opening the chat costs a few unwraps, not one per pack file (it was 20 and more).
    @Test @MainActor func openingTheChatUnwrapsTheKeyOnlyAFewTimes() async throws {
        let (store, vault) = try await Self.store()
        vault.reset()

        let sources = await MissionSources.open(mission: PackDownloaderTests.mission, store: store)

        #expect(sources.count > 40)
        #expect(vault.count <= MissionSources.unwrapsWhenOpening, "unwraps: \(vault.count)")
        #expect(MissionSources.unwrapsWhenOpening <= 6)
    }

    /// Opening reads exactly what the plain loader reads.
    @Test @MainActor func openingFindsTheSameSourcesAsBefore() async throws {
        let (store, _) = try await Self.store()

        let opened = await MissionSources.open(mission: PackDownloaderTests.mission, store: store)

        #expect(opened.map(\.id) == MissionSources.load(mission: PackDownloaderTests.mission, store: store).map(\.id))
    }

    @Test func theScreenSaysItIsOpening() {
        #expect(AskOpening.words == "Opening this mission's data…")
    }
}
