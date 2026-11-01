import Foundation
import Network

extension DeviceInfo {
    /// Evidence, not a claim: "offline (no network path)" in airplane mode with Wi-Fi off; otherwise the
    /// interfaces in use. Recorded with every offline spike run (#14, #15).
    static func networkStatus() async -> String {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                let kinds = [(NWInterface.InterfaceType.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired")]
                    .filter { path.usesInterfaceType($0.0) }.map(\.1)
                continuation.resume(returning: path.status == .satisfied
                    ? "ONLINE via \(kinds.isEmpty ? "other" : kinds.joined(separator: ", "))"
                    : "offline (no network path)")
            }
            monitor.start(queue: DispatchQueue(label: "network-status"))
        }
    }
}
