import Foundation
import Testing
@testable import MissionCopilot

/// The phone against the real staging (and production) server over the internet (#103 step 7):
/// https://mc-staging.lubot.ai,
/// organization kandor-e2e only (never the demo). The server session plays the operator by hand on #103:
/// it issues the code, approves the device id this test writes out, watches its nginx log for 206 during
/// the resume, and revokes the phone at the end. The key the phone pins is read from Staging.xcconfig, the
/// one the Staging app ships with. Like the local end to end, the phone's key is a software key in the
/// chip's format (the Simulator's Secure Enclave is not reliable); the real chip is the iPhone proof (#94).
///
/// The same run checks production (https://mc.lubot.ai, Release.xcconfig's keys) with MC_STAGING_TARGET=prod.
///
/// Run (the code is the server's, valid 15 minutes; the folder receives device-id, pack and done):
///   cd ios && TEST_RUNNER_MC_STAGING_CODE=<code> TEST_RUNNER_MC_STAGING_OUT=<folder> \
///     [TEST_RUNNER_MC_STAGING_TARGET=prod] \
///     xcodebuild test \
///     -project MissionCopilot.xcodeproj -scheme MissionCopilot \
///     -destination "platform=iOS Simulator,name=iPhone 13 Pro Max" -only-testing:MissionCopilotTests/StagingE2ETests
private struct Staging {
    let code: String, out: URL, prod: Bool

    static let config: Staging? = {
        let env = ProcessInfo.processInfo.environment
        guard let code = env["MC_STAGING_CODE"], let out = env["MC_STAGING_OUT"] else { return nil }
        return Staging(code: code, out: URL(fileURLWithPath: out), prod: env["MC_STAGING_TARGET"] == "prod")
    }()

    /// The server this run talks to, as the Staging or the Release build does: its only host and its keys.
    static func server(prod: Bool) throws -> ServerConfig {
        let only = ServerConfig.server(staging: !prod, debug: false)
        return try ServerConfig.from(["MCServerScheme": "https", "MCServerHost": only ?? "",
                                      "MCServerKeys": try pinnedKeys(prod ? "Release" : "Staging")],
                                     allowLocalHTTP: false, server: only)
    }

    /// The server's public key(s), as that build's settings file pins them (its comment after // dropped).
    static func pinnedKeys(_ build: String) throws -> String {
        let file = PackVerifierTests.repo.appending(path: "ios/Config/\(build).xcconfig")
        let line = try #require(try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            .first { $0.hasPrefix("MC_SERVER_KEYS") })
        let value = line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
        return (value.components(separatedBy: "//").first ?? "").trimmingCharacters(in: .whitespaces)
    }
}

@Suite(.enabled(if: Staging.config != nil, "started by hand with a staging code (#103 step 7)"), .serialized)
struct StagingE2ETests {
    let service = "missioncopilot.tests.staging.\(UUID().uuidString)"

    /// Asks every two seconds until the answer is the one wanted, for at most 15 minutes (the operator acts by
    /// hand), so it stays far below the server's limit of 120 requests a minute for one phone.
    private func waitFor(_ client: ServerClient, _ path: String, until done: (ServerClient.Outcome) -> Bool)
        async throws -> ServerClient.Outcome {
        for _ in 0..<450 {
            let outcome = await client.get(path)
            if done(outcome) { return outcome }
            try await Task.sleep(for: .seconds(2))
        }
        throw CancellationError()
    }

    private func note(_ name: String, _ text: String, in out: URL) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: out.appending(path: name))
    }

    @Test(.needsRepoFiles) func enrollGetApprovedDownloadWithACutThenGetRevokedAndShred() async throws {
        let staging = try #require(Staging.config)
        // The same lock as the Staging (or Release) build: its only host, https, its pinned keys.
        let config = try Staging.server(prod: staging.prod)
        let signer = SoftwareEvidenceSigner()

        // 1. Enroll with the operator's code; the device id goes out for the operator to approve.
        let enrolled = await Enroller(base: config.base, signer: signer).enroll(code: staging.code)
        guard case .enrolled(let deviceId) = enrolled else { Issue.record("enroll: \(enrolled)"); return }
        try note("device-id", deviceId, in: staging.out)
        let transport = RecordingTransport()
        var client = ServerClient(base: config.base, deviceId: deviceId, signer: signer,
                                  counter: RequestCounter(items: KeychainItems(service: service), account: deviceId),
                                  transport: transport)
        let clock = ServerClock()
        client.clock = clock

        // 2. Refused until the operator approves this phone; the server's clock was measured on the way.
        _ = try await waitFor(client, "/v1/devices/me") { $0.kind == .success }
        #expect(clock.isMeasured)

        // 3. The mission list: kandor-e2e, and the mission whose pack the operator published.
        guard case .success(let body, _, _) = await client.get(MissionList.path) else {
            Issue.record("no mission list"); return
        }
        let list = try MissionList.decode(body)
        #expect(list.orgId == "kandor-e2e")
        let mission = try #require(list.missions.first { $0.pack != nil })

        // 4. The pack in 1 KB pieces, the signal lost after four of them, then resumed from the bytes on the
        // phone: the operator's nginx log shows the 206 answers of the resume.
        let pack = try StagingPackSteps(client: client, transport: transport, config: config, org: list.orgId,
                                        mission: mission.id)
        let summary = try await pack.run()
        try note("pack", summary, in: staging.out)

        // 5. Revoked by the operator: the next signed request gets the shred order, checked, then acted on.
        let revoked = try await waitFor(client, "/v1/devices/me") { $0.kind == .shredOrder }
        guard case .shredOrder(let order) = revoked else { return }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let missions = MissionStore(store: try EncryptedStore.open(at: path, key: DataKey.random()),
                                    vault: SoftwareKeyVault())
        for item in list.missions { try missions.create(mission: item.id, title: item.title, now: Date()) }
        let records = DeviceRecordStore(service: service, user: "officer-7")
        try records.save(DeviceRecord(deviceId: deviceId, approved: true))

        #expect(ShredOrderAction.handle(order, records: records, missions: missions, keys: config.pinnedKeys,
                                        now: Date()) == .destroyed(list.missions.count))
        #expect(records.load() == nil)
        try note("done", "shred order checked and acted on: \(list.missions.count) missions destroyed", in: staging.out)
    }
}

/// The pack part against staging: cut after four pieces, resumed, every file checked against the manifest.
struct StagingPackSteps {
    let client: ServerClient, transport: RecordingTransport, config: ServerConfig, org: String, mission: String
    let store: MissionStore, staging: PackStaging

    init(client: ServerClient, transport: RecordingTransport, config: ServerConfig, org: String,
         mission: String) throws {
        self.client = client
        self.transport = transport
        self.config = config
        self.org = org
        self.mission = mission
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = MissionStore(store: try EncryptedStore.open(at: temp.appendingPathExtension("sqlite"),
                                                            key: DataKey.random()), vault: SoftwareKeyVault())
        staging = try PackStaging(base: temp, mission: mission)
    }

    private func download() async -> PackOutcome {
        let keys = config
        return await PackDownloader(client: client, keys: { keys.key(for: $0) }, store: store, staging: staging,
                                    chunk: 1024, freeSpace: { PackDownloader.availableSpace(at: FileManager.default
                                        .temporaryDirectory) })
            .run(org: org, mission: mission)
    }

    /// What the run saw, for the operator's check on #103.
    func run() async throws -> String {
        transport.cut(after: 4)
        #expect(await download() == .paused(.offline))
        let before = transport.fileRequests
        transport.cut(after: nil)
        guard case .verified(let ready) = await download() else { throw E2EStop.outcome("not verified") }
        #expect(transport.ranges[before].hasPrefix("bytes=0-") == false, "resumed from the bytes on the phone")
        for file in ready.manifest.files { try PackVerifier.check(file, data: try staging.ready(file)) }
        let bytes = ready.manifest.files.map(\.size).reduce(0, +)
        return "pack version \(ready.manifest.version), \(ready.manifest.files.count) files, \(bytes) bytes; "
            + "\(transport.fileRequests) Range requests, cut after 4, resumed at \(transport.ranges[before])"
    }
}

/// Runs every time (not only by hand): the keys the run reads are the ones the Staging and Release apps ship.
struct StagingKeyTests {
    private func ids(_ config: ServerConfig) -> Set<String> {
        Set(config.pinnedKeys.map { ServerConfig.keyId($0.derRepresentation) })
    }

    @Test(.needsRepoFiles) func theStagingKeyReadFromItsSettingsFileMakesAValidStagingConfig() throws {
        let config = try Staging.server(prod: false)

        #expect(config.base.absoluteString == "https://mc-staging.lubot.ai")
        #expect(ids(config) == ["4bf338c69bae5bfa"])
    }

    @Test(.needsRepoFiles) func theReleaseKeysMakeAValidProductionConfigWithTheSpare() throws {
        let config = try Staging.server(prod: true)

        #expect(config.base.absoluteString == "https://mc.lubot.ai")
        #expect(ids(config) == ["961f36f2f593bc81", "6846cc2ed260cde7"])
    }
}
