import Foundation
import Network

/// Tells the mission list when the phone gets a connection back (#92), so a paused pack download goes on by
/// itself. Only a change is reported: online, then offline, then online again.
final class NetworkWatch: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.lubobali.missioncopilot.network-watch")
    private var last: Bool?

    /// Starts watching; `changed` runs on the main actor with true when a connection is there.
    func start(_ changed: @escaping @MainActor (Bool) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let online = path.status == .satisfied
            guard online != last else { return }  // the handler runs on `queue` only
            last = online
            Task { @MainActor in changed(online) }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }

    deinit { monitor.cancel() }
}
