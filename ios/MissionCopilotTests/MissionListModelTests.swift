import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// The mission list (#92) against a stand-in server over the real signed Kandor pack: Kandor roads has a
/// pack, Kandor bridges none yet. A download ends in the store as Ready; a lost signal pauses it until the
/// connection returns; a closed store keeps the checked pack until unlock; with no signal the list is the
/// last one the server gave; an old download folder is removed once its pack is in the store.
@MainActor @Suite(.timeLimit(.minutes(1)))
final class MissionListModelTests {
    static let roads = PackDownloaderTests.mission
    static let bridges = "6f1d2c3a-0000-4000-8000-000000000002"
    static let now = PackVerifierTests.now

    let server = FakePackServer()
    let store: MissionStore
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = "missioncopilot.tests.list.\(UUID().uuidString)"
    let gate = Gate()  // closed while the app is locked: no store
    var seen: [[MissionRow]] = []
    var shredOrders: [Data] = []

    init() throws {
        store = MissionStore(store: try EncryptedStore.open(at: base.appendingPathExtension("sqlite"),
                                                            key: DataKey.random()), vault: SoftwareKeyVault())
    }

    func model(now: Date = now, wait: @escaping @Sendable (Int) async -> Void = { _ in },
               jitter: @escaping @Sendable (Int) -> Int = { $0 }) throws -> MissionListModel {
        let client = ServerClient(base: URL(string: "https://kandor-works.example.org")!,
                                  deviceId: "6f1d2c3a-1111-4000-8000-000000000007", signer: SoftwareEvidenceSigner(),
                                  counter: RequestCounter(items: KeychainItems(service: service), account: "phone"),
                                  transport: server)
        let key = PackVerifierTests.fixtureKey
        let pinned: @Sendable (String) -> P256.Signing.PublicKey? = { id in
            ServerConfig.keyId(key.derRepresentation) == id ? key : nil
        }
        let world = MissionListWorld(client: client, keys: pinned,
                                     stagingBase: base, schema: try PackSectionsTests.schema(), runways: [],
                                     freeSpace: { 1 << 30 }, now: { now }, chunk: 256, wait: wait, jitter: jitter)
        let made = MissionListModel(world: world, missions: { [unowned self] in gate.isOpen ? store : nil },
                                    onShredOrder: { [unowned self] in shredOrders.append($0) })
        made.onChange = { [unowned self] in seen.append($0) }
        return made
    }

    func row(_ model: MissionListModel, _ id: String) -> MissionRow? { model.rows.first { $0.id == id } }

    private func downloaded() async throws -> MissionListModel {
        let list = try model()
        await list.refresh()
        list.download(Self.roads)
        await list.downloadsEnded()
        return list
    }

    // The list

    @Test(.needsRepoFiles) func bothKandorMissionsAreListedAndOnlyRoadsCanBeDownloaded() async throws {
        let list = try model()

        await list.refresh()

        #expect(list.rows.map(\.title) == ["Kandor Rural Roads Project, Package 1", "Kandor Bridges"])
        #expect(row(list, Self.roads)?.status == .notDownloaded(available: true))
        #expect(row(list, Self.roads)?.canDownload == true)
        #expect(row(list, Self.bridges)?.status == .notDownloaded(available: false))
        #expect(row(list, Self.bridges)?.canDownload == false)
        #expect(try store.cachedMissionList()?.orgId == "kandor-works")
    }

    @Test(.needsRepoFiles) func aDownloadShowsItsBytesThenEndsInTheStoreAsReady() async throws {
        let list = try await downloaded()

        #expect(row(list, Self.roads)?.status == .ready(updated: Self.now) && row(list, Self.roads)?.version == 1)
        #expect(row(list, Self.roads)?.canDownload == false)
        #expect(seen.contains { $0.first?.status == .downloading(done: PackDownloaderTests.packBytes,
                                                                 total: PackDownloaderTests.packBytes) })
        #expect(try store.storedPack(for: Self.roads)?.files.count == 12)
        #expect(row(list, Self.roads)?.pack?.files == 12)
        #expect(row(list, Self.roads)?.pack?.bytes == PackDownloaderTests.packBytes)
        #expect(row(list, Self.roads)?.pack?.checklist == ChecklistSummary(questions: 9, french: true))
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent(Self.roads).path()))
        #expect(row(list, Self.bridges)?.status == .notDownloaded(available: false))
    }

    @Test(.needsRepoFiles) func aProgressReportArrivingAfterTheDownloadEndedChangesNothing() async throws {
        let list = try await downloaded()  // run number 1

        list.progress(Self.roads, run: 1, .downloading(done: 5, total: 10))

        #expect(row(list, Self.roads)?.status == .ready(updated: Self.now))
    }

    // Stopped, and going on by itself

    @Test(.needsRepoFiles) func aLostSignalPausesAndTheDownloadGoesOnWhenTheConnectionReturns() async throws {
        let list = try model()
        await list.refresh()
        server.dropOnce = 6

        list.download(Self.roads)
        await list.downloadsEnded()
        #expect(row(list, Self.roads)?.status == .paused(.offline))
        list.connectionChanged(online: true)
        await list.downloadsEnded()

        #expect(row(list, Self.roads)?.status == .ready(updated: Self.now))
        #expect(server.bytesSent == PackDownloaderTests.packBytes)  // not one byte twice
    }

    @Test(.needsRepoFiles) func aDownloadLeftHalfDoneWhenTheAppClosedGoesOnAtTheNextOpen() async throws {
        let first = try model()
        await first.refresh()
        server.dropOnce = 6
        first.download(Self.roads)
        await first.downloadsEnded()

        let reopened = try model()
        await reopened.refresh()
        await reopened.downloadsEnded()

        #expect(row(reopened, Self.roads)?.status == .ready(updated: Self.now))
    }

    @Test(.needsRepoFiles) func aPackCheckedWhileTheAppWasLockedIsAddedAfterUnlock() async throws {
        let list = try model()
        await list.refresh()
        let gate = gate
        server.onFileRequest = { number in if number == 3 { gate.isOpen = false } }  // locked mid-download

        list.download(Self.roads)
        await list.downloadsEnded()
        #expect(row(list, Self.roads)?.status == .paused(.locked))
        gate.isOpen = true
        await list.refresh()

        #expect(row(list, Self.roads)?.status == .ready(updated: Self.now))
    }

    // No signal, a newer pack, an old folder

    @Test(.needsRepoFiles) func withNoSignalTheLastListAndThePacksOnThePhoneStillShow() async throws {
        _ = try await downloaded()
        server.offline = true

        let offline = try model()
        await offline.refresh()

        #expect(offline.message == MissionRow.offline)
        #expect(row(offline, Self.roads)?.status == .ready(updated: Self.now))
        #expect(row(offline, Self.bridges)?.status == .notDownloaded(available: false))
    }

    @Test(.needsRepoFiles) func aNewerPackOnTheServerCanBeDownloadedWhileTheOldOneStaysReady() async throws {
        let list = try await downloaded()
        server.missionList = (200, FakePackServer.missions(version: 2))

        await list.refresh()

        #expect(row(list, Self.roads)?.updateAvailable == true && row(list, Self.roads)?.canDownload == true)
        #expect(row(list, Self.roads)?.status == .ready(updated: Self.now))
    }

    @Test(.needsRepoFiles) func aStoppedUpdateLeavesTheMissionReadyWithANote() async throws {
        let list = try await downloaded()
        server.missionList = (200, FakePackServer.missions(version: 2))
        await list.refresh()
        server.offline = true

        list.download(Self.roads)
        await list.downloadsEnded()

        #expect(row(list, Self.roads)?.status == .ready(updated: Self.now))
        #expect(row(list, Self.roads)?.note == "Update paused, waiting for connection.")
    }

    /// #104: a server that refuses this app as too old changes nothing on the phone.
    @Test(.needsRepoFiles) func anAppTooOldKeepsItsReadyPackAndSaysUpdateTheApp() async throws {
        let list = try await downloaded()
        server.missionList = (200, FakePackServer.missions(version: 2))
        await list.refresh()
        server.manifestStatus = (403, AppTooOldTests.tooOld)

        list.download(Self.roads)
        await list.downloadsEnded()

        #expect(row(list, Self.roads)?.status == .ready(updated: Self.now))
        #expect(row(list, Self.roads)?.note == "Update failed: this app is too old for the server. Update the app.")
        #expect(try store.storedPack(for: Self.roads)?.version == 1)
        let requests = server.requests.count
        await list.downloadsEnded()
        #expect(server.requests.count == requests)  // never tried again by itself
    }

    @Test(.needsRepoFiles) func theListSaysUpdateTheAppWhenTheServerRefusesThisBuild() async throws {
        let list = try model()
        server.missionList = (403, AppTooOldTests.tooOld)

        await list.refresh()

        #expect(list.message == MissionRow.appTooOld)
    }

    @Test(.needsRepoFiles) func anOldDownloadFolderIsRemovedOnceItsPackIsInTheStore() async throws {
        let list = try await downloaded()
        let leftover = base.appendingPathComponent(Self.roads, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)

        await list.refresh()

        #expect(!FileManager.default.fileExists(atPath: leftover.path()))
    }

    @Test(.needsRepoFiles) func anExpiredPackIsShownRedAndCanBeDownloadedAgain() async throws {
        _ = try await downloaded()

        let later = try model(now: Date(timeIntervalSince1970: 2_200_000_000))
        server.missionList = (200, FakePackServer.missions(version: 1))
        await later.refresh()

        guard case .expired = row(later, Self.roads)?.status else { Issue.record("not expired"); return }
        #expect(row(later, Self.roads)?.canDownload == true)
    }

    // What the server says about this phone

    @Test(.needsRepoFiles) func aPhoneNotApprovedYetIsToldSo() async throws {
        server.missionList = (401, Data())
        let list = try model()

        await list.refresh()

        #expect(list.message == MissionRow.notApproved && list.rows.isEmpty)
    }

    @Test(.needsRepoFiles) func aShredOrderIsHandedOnUntouched() async throws {
        let order = Data("signed order".utf8)
        server.missionList = (410, order)
        let list = try model()

        await list.refresh()

        #expect(shredOrders == [order])
    }
}

/// Open or closed, flipped from any thread (the fake server's hook runs off the main actor).
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    var isOpen: Bool {
        get { lock.withLock { open } }
        set { lock.withLock { open = newValue } }
    }
}
