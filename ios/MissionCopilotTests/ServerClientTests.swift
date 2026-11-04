import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// The app's only way to the server (#90): every request is signed by the phone's chip key over the
/// exact bytes the server checks, numbered so it can be used once, and every answer becomes one plain
/// outcome the screens can act on. Nothing is cached or kept in cookies.
@Suite(.serialized) struct ServerClientTests {
    let service = "missioncopilot.tests.client.\(UUID().uuidString)"
    let signer = SoftwareEvidenceSigner()
    static let base = URL(string: "https://kandor-works.example.org")!
    static let path = "/v1/missions/6f1d2c3a-0000-4000-8000-000000000001/pack/manifest"

    private func client(_ transport: FakeTransport, base: URL = Self.base, allowLocal: Bool = false)
        -> ServerClient {
        let counter = RequestCounter(items: KeychainItems(service: service), account: "device-1",
                                     now: { Date(timeIntervalSince1970: 1_793_000_000) })
        return ServerClient(base: base, deviceId: "device-1", signer: signer, counter: counter,
                            transport: transport, now: { Date(timeIntervalSince1970: 1_793_000_123) },
                            allowLocalHTTP: allowLocal)
    }

    @Test func aRequestIsSignedOverTheExactBytesTheServerChecks() async throws {
        let transport = FakeTransport(status: 200, body: Data("{}".utf8))

        _ = await client(transport).get(Self.path)

        let sent = try #require(transport.sent.first)
        let headers = sent.allHTTPHeaderFields ?? [:]
        let seq = try #require(Int(headers["X-Device-Seq"] ?? ""))
        let message = try DeviceSigning.requestMessage(SignedRequest(
            method: "GET", path: Self.path, deviceId: "device-1", seq: seq, time: 1_793_000_123, body: Data()))
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: try #require(Data(base64Encoded: headers["X-Device-Signature"] ?? "")))
        let key = try P256.Signing.PublicKey(derRepresentation: signer.publicKeyDER())
        #expect(key.isValidSignature(signature, for: message))
        #expect(headers["X-Device-Id"] == "device-1" && headers["X-Device-Time"] == "1793000123")
        #expect(sent.url?.absoluteString == Self.base.absoluteString + Self.path)
        #expect(sent.httpMethod == "GET")
    }

    @Test func aPostSignsItsBodyAndSendsIt() async throws {
        let transport = FakeTransport(status: 200)
        let body = Data(#"{"items":[]}"#.utf8)

        _ = await client(transport).post("/v1/missions/m/sync", body: body)

        let sent = try #require(transport.sent.first)
        let headers = sent.allHTTPHeaderFields ?? [:]
        let message = try DeviceSigning.requestMessage(SignedRequest(
            method: "POST", path: "/v1/missions/m/sync", deviceId: "device-1",
            seq: Int(headers["X-Device-Seq"] ?? "") ?? 0, time: 1_793_000_123, body: body))
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: Data(base64Encoded: headers["X-Device-Signature"] ?? "") ?? Data())
        #expect(try P256.Signing.PublicKey(derRepresentation: signer.publicKeyDER())
            .isValidSignature(signature, for: message))
        #expect(sent.httpBody == body && headers["Content-Type"] == "application/json")
    }

    @Test func everyRequestHasAHigherNumber() async throws {
        let transport = FakeTransport(status: 200)
        let client = client(transport)

        for _ in 0..<3 { _ = await client.get(Self.path) }

        let numbers = transport.sent.compactMap { Int($0.value(forHTTPHeaderField: "X-Device-Seq") ?? "") }
        #expect(numbers.count == 3 && numbers == numbers.sorted() && Set(numbers).count == 3)
    }

    @Test func extraHeadersLikeRangeAreSentButNeverReplaceTheSignedOnes() async throws {
        let transport = FakeTransport(status: 206)

        _ = await client(transport).get(Self.path, headers: ["Range": "bytes=10-", "X-Device-Id": "someone"])

        let sent = try #require(transport.sent.first)
        #expect(sent.value(forHTTPHeaderField: "Range") == "bytes=10-")
        #expect(sent.value(forHTTPHeaderField: "X-Device-Id") == "device-1")
    }

    @Test(arguments: [
        (200, ServerClient.Kind.success), (206, .success), (401, .refused), (404, .notFound), (410, .shredOrder),
        (416, .rangeOutside), (429, .slowDown), (500, .failed), (403, .failed), (502, .busy), (503, .busy),
        (504, .busy)
    ])
    func everyAnswerBecomesOneOutcome(status: Int, kind: ServerClient.Kind) async {
        #expect(await client(FakeTransport(status: status)).get(Self.path).kind == kind)
    }

    @Test func aShredOrderKeepsItsBodyForTheCheck() async {
        let body = Data(#"{"order":{}}"#.utf8)

        let outcome = await client(FakeTransport(status: 410, body: body)).get(Self.path)

        #expect(outcome == .shredOrder(body))
    }

    @Test(arguments: [("30", 30), ("not a number", 60), (nil, 60), ("Mon, 26 Oct 2026 07:36:53 GMT", 90)])
    func slowDownSaysHowLongToWait(header: String?, seconds: Int) async {
        let headers = header.map { ["Retry-After": $0] } ?? [:]

        #expect(await client(FakeTransport(status: 429, headers: headers)).get(Self.path) == .slowDown(seconds))
    }

    /// #104: a server restarting or overloaded (502, 503, 504) is busy, not broken. Retry-After is seconds or
    /// an HTTP date (RFC 9110 10.2.3); nil when it says nothing usable, so the phone picks its own wait.
    @Test(arguments: [("30", 30), ("0", 0), ("Mon, 26 Oct 2026 07:36:53 GMT", 90),
                      ("Mon, 26 Oct 2026 07:25:23 GMT", 0), ("-5", nil), ("soon", nil),
                      (nil, nil)] as [(String?, Int?)])
    func aBusyServerSaysHowLongToWaitIfItKnows(header: String?, seconds: Int?) async {
        let headers = header.map { ["Retry-After": $0] } ?? [:]

        #expect(await client(FakeTransport(status: 503, headers: headers)).get(Self.path) == .busy(seconds))
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost,
                      .cannotFindHost, .cannotConnectToHost, .dataNotAllowed])
    func noSignalIsOffline(code: URLError.Code) async {
        #expect(await client(FakeTransport([.failure(URLError(code))])).get(Self.path) == .offline)
    }

    @Test func aPathOutsideTheAPIIsNeverSent() async {
        let transport = FakeTransport(status: 200)

        let outcome = await client(transport).get("/admin")

        #expect(outcome == .notSent && transport.sent.isEmpty)
    }

    @Test(arguments: ["http://kandor-works.example.org", "http://192.168.1.20:8110"])
    func plainHTTPToAnotherMachineIsNeverSent(address: String) async {
        let transport = FakeTransport(status: 200)
        // swiftlint:disable:next force_unwrapping
        let outcome = await client(transport, base: URL(string: address)!, allowLocal: true).get(Self.path)

        #expect(outcome == .notSent && transport.sent.isEmpty)
    }

    @Test(arguments: ["http://127.0.0.1:8110", "http://localhost:8110", "http://lubos-mac.local:8110"])
    func plainHTTPToThisMachineOrTheLocalNetworkOnlyWhenAllowed(address: String) async {
        let local = URL(string: address)!  // swiftlint:disable:this force_unwrapping

        #expect(await client(FakeTransport(status: 200), base: local, allowLocal: false).get(Self.path) == .notSent)
        #expect(await client(FakeTransport(status: 200), base: local, allowLocal: true).get(Self.path).kind == .success)
    }

    @Test func theRealNetworkKeepsNoCacheAndNoCookies() {
        let configuration = URLSessionTransport.configuration()

        #expect(configuration.urlCache == nil && configuration.httpCookieStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpShouldSetCookies == false)
    }
}
