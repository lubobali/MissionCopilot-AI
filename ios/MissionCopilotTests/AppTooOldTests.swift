import Foundation
import Testing
@testable import MissionCopilot

/// "Update the app" (#104, 104.7; the server's side is #103 step 1.10). Every phone request carries the
/// app's build number in X-App-Build; below the server's minimum the answer is 403 with code app_too_old.
/// The phone says so plainly, never tries again by itself, and never deletes anything: only a valid signed
/// shred order does that.
@MainActor @Suite(.serialized) struct AppTooOldTests {
    static let tooOld = Data((#"{"type":"about:blank","title":"Forbidden","status":403,"#
        + #""detail":"This app build is too old; update the app.","code":"app_too_old","minAppBuild":7}"#).utf8)
    let service = "missioncopilot.tests.build.\(UUID().uuidString)"
    static let base = URL(string: "https://kandor-works.example.org")!

    private func client(_ transport: FakeTransport) -> ServerClient {
        var made = ServerClient(base: Self.base, deviceId: "device-1", signer: SoftwareEvidenceSigner(),
                                counter: RequestCounter(items: KeychainItems(service: service), account: "device-1"),
                                transport: transport)
        made.appBuild = "12"
        return made
    }

    @Test func thisBuildsNumberIsAWholeNumberFromTheBundle() throws {
        let build = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)

        #expect(ServerClient.thisBuild == build)
        #expect(!build.isEmpty && build.allSatisfy(\.isNumber))
        #expect(ServerClient(base: Self.base, deviceId: "d", signer: SoftwareEvidenceSigner(),
                             counter: RequestCounter(items: KeychainItems(service: service), account: "d"))
            .appBuild == build)
    }

    @Test func everySignedRequestSaysWhichBuildItIs() async {
        let transport = FakeTransport(status: 200, body: Data("{}".utf8))

        _ = await client(transport).get("/v1/missions")
        _ = await client(transport).post("/v1/devices/me", body: Data("{}".utf8))

        #expect(transport.sent.map { $0.value(forHTTPHeaderField: "X-App-Build") } == ["12", "12"])
    }

    @Test func enrollmentSaysWhichBuildItIs() async {
        let transport = FakeTransport(status: 201, body: Data(#"{"id":"device-1"}"#.utf8))
        var enroller = Enroller(base: Self.base, signer: SoftwareEvidenceSigner(), transport: transport)
        enroller.appBuild = "12"

        _ = await enroller.enroll(code: "ABCD-EFGH-JKMN-PQRS")

        #expect(transport.sent.first?.value(forHTTPHeaderField: "X-App-Build") == "12")
    }

    @Test func tooOldIsItsOwnAnswerWithTheMinimum() async {
        let outcome = await client(FakeTransport(status: 403, body: Self.tooOld)).get("/v1/missions")

        #expect(outcome == .appTooOld(7))
        #expect(outcome.kind == .appTooOld)
    }

    @Test(arguments: [Data(), Data("not json".utf8), Data(#"{"code":"forbidden"}"#.utf8)])
    func anyOther403StaysAPlainFailure(body: Data) async {
        #expect(await client(FakeTransport(status: 403, body: body)).get("/v1/missions") == .failed(403))
    }

    @Test func enrollmentSaysUpdateTheApp() async {
        let transport = FakeTransport(status: 403, body: Self.tooOld)
        let enroller = Enroller(base: Self.base, signer: SoftwareEvidenceSigner(), transport: transport)

        #expect(await enroller.enroll(code: "ABCD-EFGH-JKMN-PQRS") == .appTooOld)
        #expect(transport.sent.count == 1)
    }

    @Test func theWordsSayUpdateTheAppAndThatNothingIsLost() {
        #expect(MissionRow.appTooOld
            == "This app is too old for the server. Update the app; the missions on this iPhone stay as they are.")
        #expect(MissionRow.text(.appTooOld) == "this app is too old for the server. Update the app.")
        #expect(EnrollmentModel.text(.appTooOld) == "This app is too old for the server. Update the app, then connect.")
    }
}
