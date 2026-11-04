import Foundation

/// One mission in the list (#92): its title, status, whether a newer pack waits on the server, whether the
/// Download button works now, and a note when an update stopped under a pack that still works.
struct MissionRow: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let status: MissionStatus
    let pack: PackFacts?  // the pack on the phone
    let updateAvailable: Bool
    let canDownload: Bool
    let note: String?

    static let offline = "No connection. Showing the missions from the last time this iPhone was online."
    static let notApproved = "This iPhone is not approved yet. Ask your manager, then try again."

    var version: Int? { pack?.version }

    init(id: String, title: String, status: MissionStatus, pack: PackFacts?, updateAvailable: Bool,
         canDownload: Bool, note: String?) {
        self.id = id
        self.title = title
        self.status = status
        self.pack = pack
        self.updateAvailable = updateAvailable
        self.canDownload = canDownload
        self.note = note
    }

    init(mission: ListedMission, stored: StoredPack?, activity: MissionActivity?, running: Bool, now: Date) {
        id = mission.id
        title = mission.title
        status = MissionStatus.of(stored: stored, activity: activity, listed: mission.pack != nil, now: now)
        pack = stored.map(PackFacts.init)
        updateAvailable = (mission.pack?.version ?? 0) > (stored?.version ?? Int.max)
        let usable = stored.map { $0.expiresAt > now } ?? false
        canDownload = !running && mission.pack != nil && (!usable || updateAvailable)
        switch (status, activity) {
        case (.ready, let stopped?), (.expiring, let stopped?): note = Self.text(stopped)
        default: note = nil
        }
    }

    /// A stopped download in plain words.
    static func text(_ activity: MissionActivity) -> String? {
        switch activity {
        case .downloading: nil
        case .paused(.offline): "Update paused, waiting for connection."
        case .paused(.interrupted): "Update paused. It goes on when the app is open."
        case .paused(.slowDown): "The server is busy. The update goes on shortly."
        case .paused(.locked): "Update downloaded. It is added when you unlock the app."
        case .failed(let failure): "Update failed: \(text(failure))"
        }
    }

    static func text(_ failure: PackFailure) -> String {
        switch failure {
        case .refused: "the pack did not pass its checks, so it was not used."
        case .notApproved: "this iPhone is not approved."
        case .notFound: "the server has no pack for this mission."
        case .notEnoughSpace: "not enough free space on this iPhone."
        case .badFile: "a file arrived damaged twice."
        case .server: "the server could not answer."
        case .storage: "this iPhone could not save the download."
        }
    }
}

/// What the pack summary shows about the pack on the phone.
struct PackFacts: Equatable, Sendable {
    let version: Int
    let files: Int
    let bytes: Int
    let projectRef: String
    let published: Date
    let downloaded: Date
    let expires: Date
}

extension PackFacts {
    init(_ stored: StoredPack) {
        self.init(version: stored.version, files: stored.files.count, bytes: stored.files.reduce(0) { $0 + $1.size },
                  projectRef: stored.project.projectRef, published: stored.createdAt,
                  downloaded: stored.importedAt, expires: stored.expiresAt)
    }
}
