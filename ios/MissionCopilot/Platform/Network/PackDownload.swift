import Foundation

/// What the "Ready for offline" screen shows while a pack downloads (#91, #92).
enum PackDownloadState: Equatable, Sendable {
    case checking  // the manifest and its signature
    case downloading(done: Int, total: Int)  // bytes
    case verified
    case paused(PackPause)
    case failed(PackFailure)
}

/// Stopped for now, with everything so far kept: the next run goes on from there.
enum PackPause: Equatable, Sendable {
    case offline
    case slowDown(Int)  // seconds
    case interrupted  // the system wanted the time back, or the user stopped it
}

/// Stopped, and why. A refused pack is never used; nothing was taken from it.
enum PackFailure: Equatable, Sendable {
    case refused(PackRefusal)  // the signature, the rules, the version or a file
    case notApproved  // 401: this phone is not approved (any more)
    case notFound  // 404: no pack for this mission, or not this phone's to see
    case notEnoughSpace(needed: Int64, available: Int64)
    case badFile(String)  // a file stayed wrong after one more try
    case server(Int)
    case storage  // the staging folder could not be written
}

/// How a run ended.
enum PackOutcome: Equatable, Sendable {
    case verified(PackReady)
    case paused(PackPause)
    case failed(PackFailure)
    case shredOrder(Data)  // to ShredOrderAction, which checks it before anything
}

/// A pack whose signature, rules, version and every file checked out, waiting in its staging folder for
/// the store (#92).
struct PackReady: Equatable, Sendable {
    let manifest: PackManifest
    let manifestBytes: Data
    let staging: PackStaging

    static func == (left: PackReady, right: PackReady) -> Bool {
        left.manifestBytes == right.manifestBytes && left.staging.folder == right.staging.folder
    }
}
