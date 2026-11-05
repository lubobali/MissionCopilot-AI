import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// Putting the connection together for the app (#90): one request counter per phone identity, shared
/// by every client (two counters for one phone could hand out the same number), and a build without a
/// usable server says what is missing instead of guessing.
@MainActor struct ConnectionTests {
    @Test func everyClientOfOnePhoneSharesOneCounter() {
        let first = Connection.counter(for: "device-1")

        #expect(Connection.counter(for: "device-1") === first)
        #expect(Connection.counter(for: "device-2") !== first)
    }

    /// #94, found on the iPhone: a revoked phone whose clock was 10 minutes wrong refused its genuine shred
    /// order as "not recent" and kept its missions. The order's age is now checked with the server's time.
    @Test(.needsRepoFiles) func aShredOrderIsJudgedByTheServersTimeNotThePhonesClock() throws {
        let fixture = ShredOrderTests.fixture
        let key = try P256.Signing.PublicKey(derRepresentation: fixture.serverPublicKeyDER)
        let now = Date()  // the phone's clock: far from when the order was issued
        Connection.clock.measure(sent: now, received: now, server: fixture.issuedAt + 3)
        defer { Connection.clock.measure(sent: Date(), received: Date(), server: Int(Date().timeIntervalSince1970)) }

        #expect(ShredOrderCheck.check(fixture.body, deviceId: fixture.deviceId, keys: [key], now: now)
                == .refused(.notRecent))
        #expect(ShredOrderCheck.check(fixture.body, deviceId: fixture.deviceId, keys: [key],
                                      now: Connection.serverNow()) == .valid(issuedAt: fixture.issuedAt))
    }

    /// #104: every client the app makes signs with the one measured server clock.
    @Test func everyClientSharesTheOneServerClock() throws {
        let config = try ServerConfig.from(["MCServerScheme": "https", "MCServerHost": "kandor-works.example.org",
                                            "MCServerKeys": ServerConfigBuildTests.key], allowLocalHTTP: false)
        let first = Connection.client(config, deviceId: "device-1", signer: SoftwareEvidenceSigner())
        let second = Connection.client(config, deviceId: "device-2", signer: SoftwareEvidenceSigner())

        #expect(first.clock === Connection.clock && second.clock === Connection.clock)
        #expect(first.counter === Connection.counter(for: "device-1"))
    }

    @Test(arguments: [ServerConfig.Problem.noAddress, .badAddress, .wrongServer, .noKeys, .badKey])
    func aBuildWithoutAUsableServerSaysWhatIsMissing(problem: ServerConfig.Problem) {
        #expect(!Connection.text(problem).isEmpty)
    }

    @Test func eachProblemSaysSomethingDifferent() {
        let problems: [ServerConfig.Problem] = [.noAddress, .badAddress, .wrongServer, .noKeys, .badKey]

        #expect(Set(problems.map(Connection.text)).count == problems.count)
    }
}
