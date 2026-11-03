import Foundation
import Testing
@testable import MissionCopilot

/// The phone and the real server, end to end (#90), over real HTTP to the local server. Started only by
/// scripts/e2e_phone_local.py, which plays the operator: it issues the code, approves this phone when it
/// shows up, publishes a newer pack when this phone holds the first (#91), and revokes it after the pack
/// checks. The key is a software key in the chip's format (the Simulator's Secure Enclave is not
/// reliable); the real chip is proven on the iPhone (#94).
private struct E2E {
    let base: URL, code: String, keys: String, mission: String, signals: URL

    static let config: E2E? = {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["MC_E2E_BASE"].flatMap(URL.init(string:)), let code = env["MC_E2E_CODE"],
              let keys = env["MC_E2E_KEYS"], let mission = env["MC_E2E_MISSION"],
              let signals = env["MC_E2E_SIGNALS"] else { return nil }
        return E2E(base: base, code: code, keys: keys, mission: mission, signals: URL(fileURLWithPath: signals))
    }()
}

@Suite(.enabled(if: E2E.config != nil, "started by scripts/e2e_phone_local.py"), .serialized)
struct LocalServerE2ETests {
    let service = "missioncopilot.tests.e2e.\(UUID().uuidString)"

    /// Asks again every second until the answer is the one wanted, for at most two minutes.
    private func waitFor(_ client: ServerClient, _ path: String, until done: (ServerClient.Outcome) -> Bool)
        async throws -> ServerClient.Outcome {
        for _ in 0..<120 {
            let outcome = await client.get(path)
            if done(outcome) { return outcome }
            try await Task.sleep(for: .seconds(1))
        }
        throw CancellationError()
    }

    @Test func enrollGetApprovedDownloadThePackThenGetRevokedAndShred() async throws {
        let e2e = try #require(E2E.config)
        let host = "\(e2e.base.host() ?? ""):\(e2e.base.port ?? 80)"
        let config = try ServerConfig.from(["MCServerScheme": e2e.base.scheme ?? "", "MCServerHost": host,
                                            "MCServerKeys": e2e.keys], allowLocalHTTP: true)
        let signer = SoftwareEvidenceSigner()

        // 1. Enroll with the operator's code.
        let enroller = Enroller(base: config.base, signer: signer, allowLocalHTTP: true)
        let enrolled = await enroller.enroll(code: e2e.code)
        guard case .enrolled(let deviceId) = enrolled else { Issue.record("enroll: \(enrolled)"); return }
        let transport = RecordingTransport()
        let client = ServerClient(base: config.base, deviceId: deviceId, signer: signer,
                                  counter: RequestCounter(items: KeychainItems(service: service), account: deviceId),
                                  transport: transport, allowLocalHTTP: true)

        // 2. Refused until the operator approves this phone.
        _ = try await waitFor(client, "/v1/devices/me") { $0.kind == .success }

        // 3. The pack: the whole of it, cut off and resumed, a newer one taken, the older played back refused.
        try await LocalServerPackSteps(client: client, transport: transport, config: config, org: "kandor-works",
                                       mission: e2e.mission, signals: e2e.signals).run()

        // 4. Revoked: the next signed request gets the shred order, checked and then acted on.
        let revoked = try await waitFor(client, "/v1/devices/me") { $0.kind == .shredOrder }
        guard case .shredOrder(let order) = revoked else { return }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let encrypted = try EncryptedStore.open(at: path, key: DataKey.random())
        let missions = MissionStore(store: encrypted, vault: SoftwareKeyVault())
        for name in ["kandor-roads", "kandor-bridges"] { try missions.create(mission: name, title: name, now: Date()) }
        let records = DeviceRecordStore(service: service, user: "officer-7")
        try records.save(DeviceRecord(deviceId: deviceId, approved: true))

        #expect(ShredOrderAction.handle(order, records: records, missions: missions, keys: config.pinnedKeys,
                                        now: Date()) == .destroyed(2))
        #expect(records.load() == nil)
    }
}
