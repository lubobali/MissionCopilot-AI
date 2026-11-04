import Foundation
import Testing
@testable import MissionCopilot

/// A phone with a wrong clock (#104, 104.6). The server takes a signed request only within 5 minutes of its
/// own clock and refuses it like any other bad signature (401), so a phone set 10 minutes wrong would look
/// "not approved". The phone measures the difference once from GET /v1/health (unsigned, so no request
/// number is used), signs with the server's time, and measures again after a refused GET.
@Suite(.serialized) struct ServerClockTests {
    let service = "missioncopilot.tests.clock.\(UUID().uuidString)"
    static let local = 1_793_000_123  // the phone's clock
    static let server = local + 600  // the server's: the phone is 10 minutes behind
    static let path = "/v1/missions"

    static func health(_ time: Int) -> Result<FakeTransport.Answer, URLError> {
        .success(FakeTransport.Answer(status: 200, body: Data(#"{"status":"ok","time":\#(time)}"#.utf8)))
    }

    static func answer(_ status: Int) -> Result<FakeTransport.Answer, URLError> {
        .success(FakeTransport.Answer(status: status, body: Data("{}".utf8)))
    }

    private func client(_ transport: FakeTransport, clock: ServerClock? = ServerClock()) -> ServerClient {
        let counter = RequestCounter(items: KeychainItems(service: service), account: "device-1",
                                     now: { Date(timeIntervalSince1970: 0) })
        var made = ServerClient(base: URL(string: "https://kandor-works.example.org")!, deviceId: "device-1",
                                signer: SoftwareEvidenceSigner(), counter: counter, transport: transport,
                                now: { Date(timeIntervalSince1970: TimeInterval(Self.local)) })
        made.clock = clock
        return made
    }

    private func signedTime(_ request: URLRequest) -> Int? {
        request.value(forHTTPHeaderField: "X-Device-Time").flatMap { Int($0) }
    }

    @Test func theDifferenceIsMeasuredFromTheMiddleOfTheRoundTrip() {
        let clock = ServerClock()
        let sent = Date(timeIntervalSince1970: 1_000), received = Date(timeIntervalSince1970: 1_004)

        clock.measure(sent: sent, received: received, server: 1_602)

        #expect(clock.offset == 600)
        #expect(clock.time(Date(timeIntervalSince1970: 2_000)) == 2_600)
    }

    @Test func aPhoneTenMinutesBehindSignsWithTheServersTime() async {
        let transport = FakeTransport([Self.health(Self.server), Self.answer(200)])

        _ = await client(transport).get(Self.path)

        #expect(transport.sent.count == 2)
        #expect(transport.sent[0].url?.path() == "/v1/health")
        #expect(signedTime(transport.sent[1]) == Self.server)
    }

    @Test func theHealthCheckIsNotSignedAndUsesNoRequestNumber() async {
        let transport = FakeTransport([Self.health(Self.server), Self.answer(200)])

        _ = await client(transport).get(Self.path)

        let health = transport.sent[0].allHTTPHeaderFields ?? [:]
        #expect(!health.keys.contains { $0.hasPrefix("X-Device") })
        #expect(transport.sent[0].httpMethod == "GET")
        #expect(transport.sent[1].value(forHTTPHeaderField: "X-Device-Seq") == "1")
    }

    @Test func theClockIsMeasuredOnceNotBeforeEveryRequest() async {
        let transport = FakeTransport([Self.health(Self.server), Self.answer(200), Self.answer(200)])
        let phone = client(transport)

        _ = await phone.get(Self.path)
        _ = await phone.get(Self.path)

        #expect(transport.sent.map { $0.url?.path() } == ["/v1/health", Self.path, Self.path])
        #expect(signedTime(transport.sent[2]) == Self.server)
    }

    @Test(arguments: [Result<FakeTransport.Answer, URLError>.failure(URLError(.notConnectedToInternet)),
                      .success(FakeTransport.Answer(status: 200, body: Data("not json".utf8))),
                      .success(FakeTransport.Answer(status: 503))])
    func withoutTheServersTimeThePhoneUsesItsOwnAndMeasuresAgainNextTime(health: Result<FakeTransport.Answer,
                                                                                    URLError>) async {
        let transport = FakeTransport([health, Self.answer(200), Self.health(Self.server), Self.answer(200)])
        let phone = client(transport)

        _ = await phone.get(Self.path)
        _ = await phone.get(Self.path)

        #expect(signedTime(transport.sent[1]) == Self.local)
        #expect(transport.sent[2].url?.path() == "/v1/health")
        #expect(signedTime(transport.sent[3]) == Self.server)
    }

    @Test func aRefusedRequestAfterTheClockChangedIsSignedAgainOnce() async {
        let clock = ServerClock()
        clock.measure(sent: Date(timeIntervalSince1970: TimeInterval(Self.local)),
                      received: Date(timeIntervalSince1970: TimeInterval(Self.local)), server: Self.local)
        // The phone's clock was right when measured; then it was set 10 minutes back.
        let transport = FakeTransport([Self.answer(401), Self.health(Self.server), Self.answer(200)])

        let outcome = await client(transport, clock: clock).get(Self.path)

        #expect(outcome.kind == .success)
        #expect(transport.sent.map { $0.url?.path() } == [Self.path, "/v1/health", Self.path])
        #expect(signedTime(transport.sent[2]) == Self.server)
        #expect(transport.sent[2].value(forHTTPHeaderField: "X-Device-Seq")
                != transport.sent[0].value(forHTTPHeaderField: "X-Device-Seq"))
    }

    @Test func aRefusalWithTheClockRightIsNotTriedAgain() async {
        let transport = FakeTransport([Self.health(Self.server), Self.answer(401), Self.health(Self.server)])

        let outcome = await client(transport).get(Self.path)

        #expect(outcome == .refused)
        #expect(transport.sent.count == 3)  // measured, refused, measured again: same clock, so no retry
    }

    @Test func aRefusedPostIsNeverSentAgain() async {
        let transport = FakeTransport([Self.health(Self.local), Self.answer(401)])

        let outcome = await client(transport).post(Self.path, body: Data("{}".utf8))

        #expect(outcome == .refused)
        #expect(transport.sent.count == 2)
    }

    @Test func withNoClockARequestIsSignedWithThePhonesTimeLikeBefore() async {
        let transport = FakeTransport([Self.answer(200)])

        _ = await client(transport, clock: nil).get(Self.path)

        #expect(transport.sent.count == 1)
        #expect(signedTime(transport.sent[0]) == Self.local)
    }
}
