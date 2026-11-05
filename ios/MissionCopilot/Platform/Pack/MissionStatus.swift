import Foundation

/// Why a mission's download is stopped for now; every one goes on by itself later.
enum MissionPause: Equatable, Sendable {
    case offline  // no signal: goes on when the connection returns
    case interrupted  // the system took the time back: goes on at the next open
    case slowDown(Int)  // the server asked to wait: goes on by itself after these seconds (#104)
    case busy(Int)  // the server is restarting or overloaded: goes on by itself after these seconds (#104)
    case locked  // downloaded and checked, waiting for the store: goes on after unlock
    case phoneLocked  // the phone was locked mid download: goes on when the app is opened again (#94)
}

/// A download running or stopped for one mission.
enum MissionActivity: Equatable, Sendable {
    case downloading(done: Int, total: Int)
    case paused(MissionPause)
    case failed(PackFailure)
}

/// What one mission's row says (#92).
enum MissionStatus: Equatable, Sendable {
    case notDownloaded(available: Bool)  // available: the server has a pack for it
    case downloading(done: Int, total: Int)
    case paused(MissionPause)
    case ready(updated: Date)
    case expiring(updated: Date, expires: Date)
    case expired(expires: Date)
    case failed(PackFailure)

    /// "Expires soon" starts this long before the pack's expiry (amber, #92).
    static let warning: TimeInterval = 7 * 86_400

    /// The pack on the phone decides while it works; a running download always shows its bytes; with no
    /// working pack, a stopped download is the status.
    static func of(stored: StoredPack?, activity: MissionActivity?, listed: Bool, now: Date) -> MissionStatus {
        if case .downloading(let done, let total)? = activity { return .downloading(done: done, total: total) }
        if let stored, stored.expiresAt > now {
            if stored.expiresAt.timeIntervalSince(now) <= warning {
                return .expiring(updated: stored.importedAt, expires: stored.expiresAt)
            }
            return .ready(updated: stored.importedAt)
        }
        switch activity {
        case .paused(let pause)?: return .paused(pause)
        case .failed(let failure)?: return .failed(failure)
        default: break
        }
        if let stored { return .expired(expires: stored.expiresAt) }
        return .notDownloaded(available: listed)
    }

    var kind: StatusKind {
        switch self {
        case .notDownloaded: .notDownloaded
        case .downloading: .downloading
        case .paused: .paused
        case .ready: .ready
        case .expiring: .expiring
        case .expired: .expired
        case .failed: .failed
        }
    }
}
