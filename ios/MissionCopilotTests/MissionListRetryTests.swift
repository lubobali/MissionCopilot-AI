import Foundation
import Testing
@testable import MissionCopilot

/// A busy or restarting server (#104): the download pauses, the phone really waits the time it shows, then
/// goes on by itself with newly signed requests, from the bytes it has. A server that stays busy gets 5
/// tries, then the person decides ("Try again"). A download that keeps moving starts its count again.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct MissionListRetryTests {
    let rig: MissionListModelTests
    let waited = Waits()

    init() throws { rig = try MissionListModelTests() }

    /// The waits the model asked for, in order (the tests wait no real time).
    final class Waits: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: [Int] = []
        var all: [Int] { lock.withLock { seconds } }
        func add(_ value: Int) { lock.withLock { seconds.append(value) } }
    }

    /// A wait that lasts until the test lets it go.
    final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            await withCheckedContinuation { next in
                let now = lock.withLock { () -> Bool in
                    if released { return true }
                    waiting = next
                    return false
                }
                if now { next.resume() }
            }
        }

        func release() {
            let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                defer { waiting = nil }
                return waiting
            }
            next?.resume()
        }
    }

    private func list(jitter: @escaping @Sendable (Int) -> Int = { $0 },
                      onWait: @escaping @Sendable () async -> Void = {}) async throws -> MissionListModel {
        let waited = waited
        let model = try rig.model(wait: { waited.add($0); await onWait() }, jitter: jitter)
        await model.refresh()
        return model
    }

    private var roads: String { MissionListModelTests.roads }

    /// The list's message says what really happened: no signal, a busy server, or a server that failed.
    @Test(.needsRepoFiles, arguments: [(503, MissionRow.serverBusy), (429, MissionRow.serverBusy),
                                       (500, MissionRow.serverFailed)])
    func theListSaysTheServerIsBusyNotThatThereIsNoConnection(status: Int, message: String) async throws {
        let model = try await list()
        rig.server.missionList = (status, Data())

        await model.refresh()

        #expect(model.message == message)
        #expect(!message.contains("connection"))
    }

    @Test(.needsRepoFiles) func onlyALostSignalSaysNoConnection() async throws {
        let model = try await list()
        rig.server.offline = true

        await model.refresh()

        #expect(model.message == MissionRow.offline)
    }

    @Test func theListMessagesSayWhatHappenedAndWhatToDo() {
        #expect(MissionRow.serverBusy == "The server is busy or restarting. Showing the missions from the last "
                + "time it answered. Pull down to try again.")
        #expect(MissionRow.serverFailed == "The server could not answer. Showing the missions from the last "
                + "time it answered. Pull down to try again.")
    }

    @Test(.needsRepoFiles) func aServerRestartingMidDownloadPausesThenTheDownloadGoesOnByItself() async throws {
        let model = try await list()
        rig.server.busyAt = [3]

        model.download(roads)
        await model.downloadsEnded()

        #expect(rig.row(model, roads)?.status == .ready(updated: MissionListModelTests.now))
        #expect(waited.all == [5])
        #expect(rig.server.bytesSent == PackDownloaderTests.packBytes)  // not one byte twice
    }

    @Test(.needsRepoFiles) func theScreenShowsTheWaitThePhoneReallyWaits() async throws {
        let model = try await list()
        rig.server.busyAt = [3]
        rig.server.busyRetryAfter = "30"

        model.download(roads)
        await model.downloadsEnded()

        #expect(waited.all == [30])
        #expect(rig.seen.contains { $0.first { $0.id == roads }?.status == .paused(.busy(30)) })
    }

    @Test(.needsRepoFiles, arguments: [("1", 5), (nil, 5), ("9999", 300)] as [(String?, Int)])
    func theScreenShowsTheKeptWaitNotTheServersNumber(header: String?, seconds: Int) async throws {
        let model = try await list()
        rig.server.busyAt = [3]
        rig.server.busyRetryAfter = header

        model.download(roads)
        await model.downloadsEnded()

        #expect(waited.all == [seconds])
        #expect(rig.seen.contains { $0.first { $0.id == roads }?.status == .paused(.busy(seconds)) })
    }

    @Test(.needsRepoFiles) func aDownloadThatWentOnAnotherWayIsNotStartedAgainAfterTheWait() async throws {
        let hold = Hold()
        let model = try await list(onWait: { await hold.wait() })
        rig.server.busyAt = [3]
        model.download(roads)
        while rig.row(model, roads)?.status != .paused(.busy(5)) { await Task.yield() }

        model.connectionChanged(online: true)  // it goes on another way while the phone waits
        while rig.row(model, roads)?.status != .ready(updated: MissionListModelTests.now) { await Task.yield() }
        let asked = rig.server.requests.count
        hold.release()
        await model.downloadsEnded()

        #expect(rig.server.requests.count == asked)
        #expect(rig.row(model, roads)?.status == .ready(updated: MissionListModelTests.now))
    }

    /// #94: on the iPhone, when airplane mode went off the app tried at once, the network was not ready, the
    /// try ended offline, and nothing tried again until a tap. An offline pause now tries again by itself.
    @Test(.needsRepoFiles) func aLostConnectionIsTriedAgainByItselfWithoutAnyNetworkChange() async throws {
        let server = rig.server
        let model = try await list(onWait: { server.offline = false })  // the network is back after the wait
        server.offline = true

        model.download(roads)
        await model.downloadsEnded()

        #expect(waited.all == [5])
        #expect(rig.row(model, roads)?.status == .ready(updated: MissionListModelTests.now))
    }

    @Test(.needsRepoFiles) func aConnectionThatStaysAwayIsTriedFiveTimesThenWaitsForTheNetwork() async throws {
        let model = try await list()
        rig.server.offline = true

        model.download(roads)
        await model.downloadsEnded()

        #expect(waited.all == [5, 10, 20, 40, 80])
        #expect(rig.row(model, roads)?.status == .paused(.offline))  // never "failed": it goes on later
        rig.server.offline = false
        model.connectionChanged(online: true)
        await model.downloadsEnded()
        #expect(rig.row(model, roads)?.status == .ready(updated: MissionListModelTests.now))
    }

    @Test(.needsRepoFiles) func slowDownWaitsTheServersTimeThenGoesOn() async throws {
        let server = rig.server
        let model = try await list(onWait: { server.manifestStatus = nil })  // the server is fine again
        server.manifestStatus = (429, Data())

        model.download(roads)
        await model.downloadsEnded()

        #expect(waited.all == [60])
        #expect(rig.row(model, roads)?.status == .ready(updated: MissionListModelTests.now))
    }

    @Test(.needsRepoFiles) func aServerThatStaysBusyGetsFiveTriesThenThePersonDecides() async throws {
        let model = try await list()
        rig.server.busyFrom = 1

        model.download(roads)
        await model.downloadsEnded()

        #expect(waited.all == [5, 10, 20, 40, 80])
        #expect(rig.row(model, roads)?.status == .failed(.serverBusy))
    }

    @Test(.needsRepoFiles) func aDownloadThatKeepsMovingStartsItsCountAgain() async throws {
        let model = try await list()
        rig.server.busyAt = [3, 6, 9, 12, 15, 18, 21]

        model.download(roads)
        await model.downloadsEnded()

        #expect(waited.all == Array(repeating: 5, count: 7))
        #expect(rig.row(model, roads)?.status == .ready(updated: MissionListModelTests.now))
    }

    @Test(.needsRepoFiles) func eachWaitIsRandomUnderItsCap() async throws {
        let model = try await list(jitter: { $0 / 2 + 3 })
        rig.server.busyFrom = 1

        model.download(roads)
        await model.downloadsEnded()

        #expect(waited.all == [5, 8, 13, 23, 43])
    }
}
