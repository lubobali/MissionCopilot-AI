import Foundation
import Testing
@testable import MissionCopilot

/// The mission list part of the end to end test (#92): the app's own MissionListModel, with the bundled
/// pack sections schema and the app's background time, against the real server. Both Kandor missions are
/// listed for officer-7; roads downloads and goes into the encrypted store as Ready at the newest version,
/// bridges stays Not downloaded (no pack published), and the download folder is gone afterwards.
@MainActor struct LocalServerListSteps {
    let client: ServerClient, config: ServerConfig
    let roads: String, bridges: String, newest: Int

    func run() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MissionStore(store: try EncryptedStore.open(at: temp.appendingPathExtension("sqlite"),
                                                                key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        let config = config
        let world = MissionListWorld(client: client, keys: { config.key(for: $0) }, stagingBase: temp,
                                     schema: try PackSchema.bundled(),
                                     freeSpace: { PackDownloader.availableSpace(at: .homeDirectory) })
        let list = MissionListModel(world: world, missions: { store })
        let row = { (id: String) in list.rows.first { $0.id == id } }

        // 1. Both missions listed: roads can be downloaded, bridges has no pack yet.
        await list.refresh()
        #expect(list.message == nil)
        #expect(Set(list.rows.map(\.id)) == [roads, bridges])
        #expect(row(roads)?.status == .notDownloaded(available: true) && row(roads)?.canDownload == true)
        #expect(row(bridges)?.status == .notDownloaded(available: false) && row(bridges)?.canDownload == false)

        // 2. Roads downloaded, checked and imported: Ready at the newest version, the folder gone.
        list.download(roads)
        await list.downloadsEnded()
        guard case .ready? = row(roads)?.status else {
            throw E2EStop.outcome("roads: \(String(describing: row(roads)))")
        }
        let stored = try #require(try store.storedPack(for: roads))
        #expect(stored.version == newest && row(roads)?.pack?.version == newest)
        #expect(stored.files.count == row(roads)?.pack?.files && !stored.files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: temp.appendingPathComponent(roads).path()))
        #expect(row(bridges)?.status == .notDownloaded(available: false))
    }
}
