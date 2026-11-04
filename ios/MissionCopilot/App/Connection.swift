import SwiftUI

/// Puts the connection to the organization's server together for the app (#90): the chip key that
/// signs, the Keychain record of this phone's enrollment, and one request counter per phone identity,
/// shared by every client, so two requests can never be given the same number. One server clock too
/// (#104), so the phone's clock is measured once and every request is signed with the server's time.
@MainActor enum Connection {
    static let counterService = "com.lubobali.missioncopilot.requests"
    static let clock = ServerClock()
    private static var counters: [String: RequestCounter] = [:]

    /// Every client of the organization's server: its counter and the shared clock always attached.
    static func client(_ config: ServerConfig, deviceId: String, signer: EvidenceSigner) -> ServerClient {
        var made = ServerClient(base: config.base, deviceId: deviceId, signer: signer,
                                counter: counter(for: deviceId), allowLocalHTTP: config.allowLocalHTTP)
        made.clock = clock
        return made
    }

    static func counter(for deviceId: String) -> RequestCounter {
        if let found = counters[deviceId] { return found }
        let made = RequestCounter(items: KeychainItems(service: counterService), account: deviceId)
        counters[deviceId] = made
        return made
    }

    static func enrollment(_ config: ServerConfig, user: String,
                           missions: @escaping @MainActor () -> MissionStore?) -> EnrollmentModel {
        let signer = SecureEnclaveEvidenceSigner(user: user)
        let enroller = Enroller(base: config.base, signer: signer, allowLocalHTTP: config.allowLocalHTTP)
        let records = DeviceRecordStore(user: user)
        return EnrollmentModel(
            enroller: enroller, records: records,
            client: { deviceId in client(config, deviceId: deviceId, signer: signer) },
            onShredOrder: { body in
                ShredOrderAction.handle(body, records: records, missions: missions(), keys: config.pinnedKeys,
                                        now: Date())
            })
    }

    /// What a build without a usable server says.
    nonisolated static func text(_ problem: ServerConfig.Problem) -> String {
        switch problem {
        case .noAddress: "This build has no server address. Ask your organization for its build of the app."
        case .badAddress: "This build's server address is not allowed: it must use https."
        case .wrongServer: "This build names a server it may not use. Ask your organization for its build of the app."
        case .noKeys: "This build has no server key, so it could not trust any mission pack."
        case .badKey: "This build's server key is not a valid P-256 key."
        }
    }
}

/// The screen behind "Connect this iPhone": enrollment when the build has a usable server, otherwise
/// what is missing.
struct ConnectionScreen: View {
    let user: String
    let missions: @MainActor () -> MissionStore?
    @State private var model: EnrollmentModel?
    @State private var problem: ServerConfig.Problem?

    var body: some View {
        Group {
            if let model {
                EnrollmentView(model: model)
            } else if let problem {
                Text(Connection.text(problem))
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .fieldScreen()
            }
        }
        .task {
            do throws(ServerConfig.Problem) {
                model = Connection.enrollment(try ServerConfig.fromApp(), user: user, missions: missions)
            } catch {
                problem = error
            }
        }
    }
}
