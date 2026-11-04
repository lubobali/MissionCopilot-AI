import Foundation

/// The difference between this phone's clock and the server's (#104). The server takes a signed request
/// only within 5 minutes of its own time and refuses it like any bad signature, so a phone whose clock is
/// wrong would look "not approved". The difference is measured from GET /v1/health and taken at the middle
/// of the round trip, so the network's delay does not count. Shared by every client of one server.
final class ServerClock: @unchecked Sendable {
    /// A change smaller than this after a refusal is not the reason for it: nothing is sent again.
    static let meaningful: TimeInterval = 60

    private let lock = NSLock()
    private var measured: TimeInterval?

    var isMeasured: Bool { lock.withLock { measured != nil } }
    var offset: TimeInterval { lock.withLock { measured ?? 0 } }

    func measure(sent: Date, received: Date, server: Int) {
        let middle = (sent.timeIntervalSince1970 + received.timeIntervalSince1970) / 2
        lock.withLock { measured = TimeInterval(server) - middle }
    }

    /// The server's time now, in whole Unix seconds, as the signed request carries it.
    func time(_ local: Date) -> Int { Int((local.timeIntervalSince1970 + offset).rounded(.down)) }
}
