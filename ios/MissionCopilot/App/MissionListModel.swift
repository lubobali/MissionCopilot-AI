import CryptoKit
import Foundation
import Observation

/// What the mission list needs from the world, so the tests can play every part of it.
struct MissionListWorld: Sendable {
    let client: ServerClient
    let keys: @Sendable (String) -> P256.Signing.PublicKey?
    let stagingBase: URL
    let schema: PackSchema
    var runways: [BackgroundRunway] = KeepGoing.runways
    var freeSpace: @Sendable () -> Int64
    var now: @Sendable () -> Date = { Date() }
    var chunk = 1 << 20
    /// The real wait before a busy server is tried again, and the random part of it (#104).
    var wait: @Sendable (Int) async -> Void = { seconds in try? await Task.sleep(for: .seconds(seconds)) }
    var jitter: @Sendable (Int) -> Int = { cap in Int.random(in: 0...cap) }
}

/// The mission list (#92): the server's list joined with the packs in the encrypted store. A download
/// goes through KeepGoing and PackDownloader, then PackImport; it goes on by itself when the connection
/// returns, when the app opens, and (if the store was closed when it finished) after the next unlock. A busy
/// server (#104) is tried again by itself after the wait the row shows (Backoff), at most Backoff.maxTries
/// times in a row; a run that moved bytes starts the count again.
/// With no signal the list is the last one the server gave, kept in the store.
@MainActor @Observable final class MissionListModel {
    private(set) var rows: [MissionRow] = []
    private(set) var message: String?
    /// Told after every change of the rows (the tests watch progress with it).
    var onChange: (([MissionRow]) -> Void)?

    private let world: MissionListWorld
    private let missions: @MainActor () -> MissionStore?
    private let onShredOrder: (Data) -> Void
    private var list: MissionList?
    private var activity: [String: MissionActivity] = [:]
    private var running: [String: Int] = [:]
    private var generation = 0
    private var waiting: [String: PackReady] = [:]  // checked, waiting for the store to open
    private var tasks: [String: Task<Void, Never>] = [:]
    private var tries: [String: Int] = [:]  // busy answers in a row, per mission
    private var offlineTries: [String: Int] = [:]  // tries with no connection in a row, per mission (#94)
    private var retries: [String: Task<Void, Never>] = [:]  // a wait before the next try

    init(world: MissionListWorld, missions: @escaping @MainActor () -> MissionStore?,
         onShredOrder: @escaping (Data) -> Void = { _ in }) {
        self.world = world
        self.missions = missions
        self.onShredOrder = onShredOrder
    }

    func refresh() async {
        message = nil
        switch await world.client.get(MissionList.path) {
        case .success(let data, _, _):
            if let fresh = try? MissionList.decode(data) {
                list = fresh
                try? missions()?.cacheMissionList(fresh)
            }
        case .refused:
            message = MissionRow.notApproved
        case .shredOrder(let body):
            onShredOrder(body)
            return
        case .offline:
            message = MissionRow.offline
        case .phoneLocked:
            break  // the list from the last time stays; it is asked again when the app opens
        case .busy, .slowDown:
            message = MissionRow.serverBusy
        case .appTooOld:
            message = MissionRow.appTooOld
        default:
            message = MissionRow.serverFailed
        }
        if list == nil { list = try? missions()?.cachedMissionList() }
        importWaiting()
        sweep()
        rebuild()
        resumeStopped()
    }

    /// The connection came back (or went): stopped downloads go on.
    func connectionChanged(online: Bool) {
        guard online else { return }
        for (id, state) in activity {
            if case .paused(let pause) = state, pause != .locked { download(id) }
        }
    }

    func download(_ id: String) {
        guard running[id] == nil, let store = missions(), let list,
              let mission = list.missions.first(where: { $0.id == id }), mission.pack != nil else { return }
        generation += 1
        let run = generation
        running[id] = run
        activity[id] = .downloading(done: 0, total: 0)
        rebuild()
        let world = world, job = Job(id: id, title: mission.title, org: list.orgId, store: store)
        tasks[id] = Task {
            let result = await Self.downloadPack(job, world: world) { [weak self] state in
                Task { @MainActor in self?.progress(id, run: run, state) }
            }
            if result.moved { tries[id] = nil; offlineTries[id] = nil }
            finish(id, run: run, title: mission.title, (result.outcome, result.staging))
        }
    }

    /// Waits until every download started so far has ended (for the tests and the end to end check).
    func downloadsEnded() async {
        while let (id, task) = tasks.first ?? retries.first {
            await task.value
            if tasks[id] == task { tasks[id] = nil }
            if retries[id] == task { retries[id] = nil }
        }
    }

    /// One mission to download, and the store whose version rule it must pass.
    private struct Job: Sendable {
        let id: String, title: String, org: String, store: MissionStore
    }

    /// How a run ended, and whether it moved any bytes (a piece came after the first report).
    private struct RunResult: Sendable {
        let outcome: PackOutcome, staging: PackStaging?, moved: Bool
    }

    private nonisolated static func downloadPack(_ job: Job, world: MissionListWorld,
                                                 onState: @escaping @Sendable (PackDownloadState) -> Void) async
        -> RunResult {
        guard let staging = try? PackStaging(base: world.stagingBase, mission: job.id) else {
            return RunResult(outcome: .failed(.storage), staging: nil, moved: false)
        }
        let reports = Reports()
        let outcome = await KeepGoing.run(title: "Downloading mission pack", subtitle: job.title,
                                          runways: world.runways) { report in
            let downloader = PackDownloader(
                client: world.client, keys: world.keys, store: job.store, staging: staging, chunk: world.chunk,
                freeSpace: world.freeSpace, now: world.now,
                onState: { state in
                    if case .downloading(let done, let total) = state {
                        reports.add()
                        report(done, total)
                    }
                    onState(state)
                })
            return await downloader.run(org: job.org, mission: job.id)
        }
        return RunResult(outcome: outcome, staging: staging, moved: reports.count > 1)
    }

    /// Progress reports of one run: the first is where it starts, every later one a piece that came.
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = 0
        var count: Int { lock.withLock { seen } }
        func add() { lock.withLock { seen += 1 } }
    }

    /// A progress report from download number `run`; one from a run that already ended is dropped (it can
    /// arrive after the end: each report hops to the main actor on its own). Internal for the tests.
    func progress(_ id: String, run: Int, _ state: PackDownloadState) {
        guard running[id] == run, case .downloading(let done, let total) = state else { return }
        activity[id] = .downloading(done: done, total: total)
        rebuild()
    }

    private func finish(_ id: String, run: Int, title: String, _ result: (PackOutcome, PackStaging?)) {
        guard running[id] == run else { return }
        running[id] = nil
        switch result.0 {
        case .verified(let ready):
            tries[id] = nil
            offlineTries[id] = nil
            importPack(ready, title: title)
        case .paused(.offline): retryOffline(id)
        case .paused(.interrupted): activity[id] = .paused(.interrupted)
        case .paused(.phoneLocked): activity[id] = .paused(.phoneLocked)
        case .paused(.slowDown(let seconds)): retryLater(id, asked: seconds) { .slowDown($0) }
        case .paused(.busy(let seconds)): retryLater(id, asked: seconds) { .busy($0) }
        case .failed(let failure): activity[id] = .failed(failure)
        case .shredOrder(let body): onShredOrder(body)
        }
        rebuild()
    }

    private func importPack(_ ready: PackReady, title: String) {
        let id = ready.manifest.missionId
        guard let store = missions() else {
            waiting[id] = ready
            activity[id] = .paused(.locked)
            return
        }
        do {
            _ = try PackImport.run(ready, title: title, into: store, schema: world.schema, now: world.now())
            waiting[id] = nil
            activity[id] = nil
        } catch .storeUnavailable {
            waiting[id] = ready
            activity[id] = .paused(.locked)
        } catch .storeFailed {
            waiting[id] = nil
            activity[id] = .failed(.storage)
        } catch {
            waiting[id] = nil
            activity[id] = .failed(.refused(error))
        }
    }

    private func importWaiting() {
        for ready in waiting.values {
            let title = list?.missions.first { $0.id == ready.manifest.missionId }?.title ?? ready.manifest.missionId
            importPack(ready, title: title)
        }
    }

    private func folder(_ id: String) -> URL { world.stagingBase.appendingPathComponent(id, isDirectory: true) }

    /// A download folder left by a mission whose newest pack is already in the store is removed (T55).
    private func sweep() {
        guard let store = missions() else { return }
        for mission in list?.missions ?? [] where running[mission.id] == nil && waiting[mission.id] == nil {
            guard let stored = try? store.storedPack(for: mission.id),
                  stored.version >= (mission.pack?.version ?? 0) else { continue }
            try? FileManager.default.removeItem(at: folder(mission.id))
        }
    }

    /// Downloads stopped earlier (or left half done when the app was closed) go on.
    private func resumeStopped() {
        for mission in list?.missions ?? [] where running[mission.id] == nil && mission.pack != nil {
            let paused = if case .paused(let pause) = activity[mission.id], pause != .locked { true } else { false }
            let halfDone = FileManager.default.fileExists(atPath: PackStaging.path(folder(mission.id)))
            if paused || halfDone { download(mission.id) }
        }
    }

    private func rebuild() {
        let store = missions(), now = world.now()
        rows = (list?.missions ?? []).map { mission in
            MissionRow(mission: mission, stored: try? store?.storedPack(for: mission.id),
                       activity: activity[mission.id], running: running[mission.id] != nil, now: now)
        }
        onChange?(rows)
    }
}

/// Trying a busy server again (#104).
extension MissionListModel {
    /// A busy server: wait the time the row shows, then try again with newly signed requests. After
    /// Backoff.maxTries busy answers in a row the person decides ("Try again").
    fileprivate func retryLater(_ id: String, asked: Int?, pause: (Int) -> MissionPause) {
        let attempt = tries[id, default: 0]
        guard attempt < Backoff.maxTries else {
            tries[id] = nil
            activity[id] = .failed(.serverBusy)
            return
        }
        let seconds = Backoff.delay(asked: asked, attempt: attempt, jitter: world.jitter)
        tries[id] = attempt + 1
        activity[id] = .paused(pause(seconds))
        schedule(id, after: seconds)
    }

    /// No connection (#94): the network may be back already but not ready (seen on the iPhone right after
    /// airplane mode went off), so try again after a growing wait, Backoff.maxTries times; then wait for the
    /// next network change. Offline a try fails at once and costs no data. It stays a pause, never a failure.
    fileprivate func retryOffline(_ id: String) {
        activity[id] = .paused(.offline)
        let attempt = offlineTries[id, default: 0]
        guard attempt < Backoff.maxTries else {
            offlineTries[id] = nil
            return
        }
        offlineTries[id] = attempt + 1
        schedule(id, after: Backoff.delay(asked: nil, attempt: attempt, jitter: world.jitter))
    }

    private func schedule(_ id: String, after seconds: Int) {
        retries[id]?.cancel()
        let wait = world.wait
        retries[id] = Task { [weak self] in
            await wait(seconds)
            guard !Task.isCancelled else { return }
            self?.tryAgain(id)
        }
    }

    fileprivate func tryAgain(_ id: String) {
        switch activity[id] {
        case .paused(.slowDown), .paused(.busy), .paused(.offline): download(id)
        default: break  // it went on another way, or the person changed it
        }
    }
}
