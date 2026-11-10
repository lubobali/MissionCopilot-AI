import Foundation
import Observation

/// Keeps the one mission list of the app (#92). It lives above the lock screen, so a download goes on while
/// the app is locked and its pack is added at unlock; the network watch reaches it from the moment it is
/// made. A build or phone that cannot list missions yet is asked again at the next open, never remembered.
@MainActor @Observable final class MissionsHub {
    enum Problem: Error, Equatable {
        case config(ServerConfig.Problem)
        case notConnected  // no approved enrollment on this phone yet
        case noSchema  // the build lacks the pack sections schema
    }

    private(set) var model: MissionListModel?
    /// After a shred order destroyed the list (#94): said on the missions and home screens, in place of a
    /// list that will not come back, until this phone is connected again and a new list opens.
    private(set) var shredNotice: String?
    private let make: @MainActor (MissionsHub) -> Result<MissionListModel, Problem>
    private let watch: (@escaping @MainActor (Bool) -> Void) -> Void
    private var watching = false

    /// - Parameters:
    ///   - make: builds the list; it gets the hub to forget the list after a shred order destroyed it.
    ///   - watch: starts telling the list when the connection comes and goes (NetworkWatch).
    init(make: @escaping @MainActor (MissionsHub) -> Result<MissionListModel, Problem>,
         watch: @escaping (@escaping @MainActor (Bool) -> Void) -> Void) {
        self.make = make
        self.watch = watch
    }

    func open() -> Result<MissionListModel, Problem> {
        if let model { return .success(model) }
        let made = make(self)
        if case .success(let fresh) = made {
            model = fresh
            shredNotice = nil
            startWatching()
        }
        return made
    }

    /// After unlock: a pack that finished while the store was closed goes in, stopped downloads go on.
    func unlocked() async { await model?.refresh() }

    /// - Parameter destroyed: how many missions a shred order destroyed, said until a new list opens.
    func forget(destroyed: Int? = nil) {
        model = nil
        if let destroyed { shredNotice = Self.shredText(destroyed) }
    }

    nonisolated static func shredText(_ count: Int) -> String {
        let missions = count == 1 ? "1 mission was" : "\(count) missions were"
        return "Your organization disconnected this iPhone, so its \(missions) destroyed. "
            + "Ask your admin before connecting again."
    }

    private func startWatching() {
        guard !watching else { return }
        watching = true
        watch { [weak self] online in self?.model?.connectionChanged(online: online) }
    }

    nonisolated static func text(_ problem: Problem) -> String {
        switch problem {
        case .config(let config): Connection.text(config)
        case .notConnected: "Connect this iPhone first. Missions show here once a manager approves it."
        case .noSchema: "This build cannot read mission packs. Ask your organization for a new build."
        }
    }
}

extension Connection {
    /// The live mission list: the build's server and keys, this phone's approved enrollment, the chip key,
    /// and a download folder per user that is never backed up (data handling: the download folder).
    static func missionsHub(user: String, missions: @escaping @MainActor () -> MissionStore?) -> MissionsHub {
        let network = NetworkWatch()
        return MissionsHub(make: { hub in
            let config: ServerConfig
            do throws(ServerConfig.Problem) { config = try ServerConfig.fromApp() } catch {
                return .failure(.config(error))
            }
            let records = DeviceRecordStore(user: user)
            guard let record = records.load(), record.approved else { return .failure(.notConnected) }
            guard let schema = try? PackSchema.bundled() else { return .failure(.noSchema) }
            let signer = SecureEnclaveEvidenceSigner(user: user)
            let client = Connection.client(config, deviceId: record.deviceId, signer: signer)
            let base = URL.applicationSupportDirectory.appending(path: "PackDownloads/\(user)",
                                                                 directoryHint: .isDirectory)
            // Measured on the app's home folder: it always exists and sits on the same volume.
            let space: @Sendable () -> Int64 = { PackDownloader.availableSpace(at: .homeDirectory) }
            let registration = ApprovalKeyRegistration(signer: SecureEnclaveApprovalSigner(user: user),
                                                       records: records)
            var world = MissionListWorld(client: client, keys: { config.key(for: $0) }, stagingBase: base,
                                         schema: schema, freeSpace: space)
            world.registerApprovalKey = { _ = await registration.ensure(client: client) }
            return .success(MissionListModel(world: world, missions: missions) { [weak hub] body in
                let phone = ShredOrderAction.Phone(records: records, forgetKey: { try? signer.deleteKey() })
                let result = ShredOrderAction.handle(body, phone: phone, missions: missions(),
                                                     keys: config.pinnedKeys, now: Connection.serverNow())
                if case .destroyed(let count) = result { hub?.forget(destroyed: count) }
            })
        }, watch: { network.start($0) })
    }
}
