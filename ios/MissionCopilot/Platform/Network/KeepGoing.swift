import BackgroundTasks
import UIKit

/// One way the system can keep work going after the user leaves the app (#91).
protocol BackgroundRunway: Sendable {
    /// Asks for time; nil if the system does not give it. `expire` is called when it wants the time back.
    @MainActor func begin(title: String, subtitle: String, expire: @escaping @Sendable () -> Void) async
        -> BackgroundLease?
}

/// Time the system gave. It sees the progress (and may show it) and is given back exactly once.
protocol BackgroundLease: Sendable {
    func progress(done: Int, total: Int)
    func end(success: Bool)
}

/// Runs a pack download so it can finish when the user leaves the app. The work starts at once, in the
/// app; the first way the system grants carries it outside: BGContinuedProcessingTask (iOS 26, shown to
/// the user with progress), else the short background time every app gets. When the system wants the time
/// back the work is cancelled: the download pauses with its bytes on disk and goes on at the next run.
/// Never a background URLSession: it would send old signed requests again, which the server refuses.
enum KeepGoing {
    static let runways: [BackgroundRunway] = [ContinuedProcessingRunway(), BackgroundTimeRunway()]

    @MainActor static func run(title: String, subtitle: String, runways: [BackgroundRunway] = runways,
                               work: @escaping @Sendable (_ report: @escaping @Sendable (Int, Int) -> Void) async
                                   -> PackOutcome) async -> PackOutcome {
        let holder = LeaseHolder()
        let task = Task { await work { done, total in holder.progress(done: done, total: total) } }
        for runway in runways {
            if let lease = await runway.begin(title: title, subtitle: subtitle, expire: { task.cancel() }) {
                holder.set(lease)
                break
            }
        }
        let outcome = await task.value
        if case .verified = outcome { holder.end(success: true) } else { holder.end(success: false) }
        return outcome
    }
}

/// The lease once granted, and the last progress for a lease that comes after it.
private final class LeaseHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: BackgroundLease?
    private var last: (done: Int, total: Int)?

    func set(_ lease: BackgroundLease) {
        lock.withLock {
            self.lease = lease
            if let last { lease.progress(done: last.done, total: last.total) }
        }
    }

    func progress(done: Int, total: Int) {
        lock.withLock {
            last = (done, total)
            lease?.progress(done: done, total: total)
        }
    }

    func end(success: Bool) { lock.withLock { lease?.end(success: success) } }
}

/// BGContinuedProcessingTask: asked for only when the user starts a download, with the .fail strategy so a
/// refusal is known at once. Every request has a new identifier under the one wildcard in Info.plist: an
/// identifier registered twice makes the system end the app. The wildcard is "<bundle id>.pack.*" and each
/// build has its own bundle id (Staging, #104), so the identifier is built from the running app's.
struct ContinuedProcessingRunway: BackgroundRunway {
    static func newIdentifier(bundle: String? = Bundle.main.bundleIdentifier) -> String? {
        guard let bundle, !bundle.isEmpty else { return nil }
        return "\(bundle).pack.\(UUID().uuidString.lowercased())"
    }

    @MainActor func begin(title: String, subtitle: String, expire: @escaping @Sendable () -> Void) async
        -> BackgroundLease? {
        guard let identifier = Self.newIdentifier() else { return nil }
        let lease = ContinuedLease(identifier: identifier, expire: expire)
        // The system runs this on a background queue (using: nil), so it must not inherit this function's main
        // actor: Swift 6 checks that at run time and stopped the app on the iPhone (#94). The lease is locked.
        let launch: @Sendable (BGTask) -> Void = { task in
            guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            lease.attach(task)
        }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil,
                                                         launchHandler: launch)
        guard registered else { return nil }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        // The Simulator, or the system cannot run it now: the short background time is next.
        return await Self.submit(request) ? lease : nil
    }

    /// iOS 27 reports every reason a request is refused only through the asynchronous call (the one that throws
    /// at once is deprecated there); iOS 26 has only that one.
    @MainActor private static func submit(_ request: BGContinuedProcessingTaskRequest) async -> Bool {
        if #available(iOS 27.0, *) {
            return (try? await BGTaskScheduler.shared.submitTaskRequest(request)) != nil
        }
        return (try? BGTaskScheduler.shared.submit(request)) != nil
    }
}

private final class ContinuedLease: BackgroundLease, @unchecked Sendable {
    private let lock = NSLock()
    private let identifier: String
    private let expire: @Sendable () -> Void
    private var task: BGContinuedProcessingTask?
    private var last = (done: 0, total: 0)
    private var ended: Bool?

    init(identifier: String, expire: @escaping @Sendable () -> Void) {
        self.identifier = identifier
        self.expire = expire
    }

    /// The system started the task, perhaps after the work already ended.
    func attach(_ task: BGContinuedProcessingTask) {
        lock.withLock {
            if let ended { return task.setTaskCompleted(success: ended) }
            self.task = task
            task.expirationHandler = { [expire] in expire() }
            show(last, on: task)
        }
    }

    func progress(done: Int, total: Int) {
        lock.withLock {
            last = (done, total)
            if let task { show(last, on: task) }
        }
    }

    func end(success: Bool) {
        lock.withLock {
            guard ended == nil else { return }
            ended = success
            if let task { task.setTaskCompleted(success: success) } else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            }
        }
    }

    private func show(_ step: (done: Int, total: Int), on task: BGContinuedProcessingTask) {
        task.progress.totalUnitCount = Int64(max(step.total, 1))
        task.progress.completedUnitCount = Int64(step.done)
    }
}

/// The short time every app gets to finish after the user leaves it.
struct BackgroundTimeRunway: BackgroundRunway {
    @MainActor func begin(title: String, subtitle: String, expire: @escaping @Sendable () -> Void) -> BackgroundLease? {
        let lease = BackgroundTimeLease()
        let identifier = UIApplication.shared.beginBackgroundTask(withName: title) {
            expire()
            lease.end(success: false)
        }
        guard identifier != .invalid else { return nil }
        lease.identifier = identifier
        return lease
    }
}

private final class BackgroundTimeLease: BackgroundLease, @unchecked Sendable {
    private let lock = NSLock()
    private var current: UIBackgroundTaskIdentifier = .invalid

    var identifier: UIBackgroundTaskIdentifier {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func progress(done: Int, total: Int) {}

    /// Given back once, on the main thread as UIKit wants; at once when already there, as the expiry
    /// handler must give it back before it returns or the system ends the app.
    func end(success: Bool) {
        let given = lock.withLock { () -> UIBackgroundTaskIdentifier in
            defer { current = .invalid }
            return current
        }
        guard given != .invalid else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(given) }
        } else {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(given) }
        }
    }
}
