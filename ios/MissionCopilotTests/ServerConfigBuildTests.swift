import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// Each build may talk to one server only (#104): Staging to the staging server, Release to production,
/// Debug to whatever the developer's Local.xcconfig names. The build settings already say so; the app
/// checks it again, so a wrong settings file shows a clear screen instead of reaching the wrong server.
struct ServerConfigBuildTests {
    static let key = ServerConfigTests.hex(P256.Signing.PrivateKey().publicKey.derRepresentation)

    private func info(host: String) -> [String: Any] {
        ["MCServerScheme": "https", "MCServerHost": host, "MCServerKeys": Self.key]
    }

    @Test func stagingTalksToStagingReleaseToProductionAndDebugToAny() {
        #expect(ServerConfig.server(staging: true, debug: false) == "mc-staging.lubot.ai")
        #expect(ServerConfig.server(staging: false, debug: false) == "mc.lubot.ai")
        #expect(ServerConfig.server(staging: false, debug: true) == nil)
        #expect(ServerConfig.server(staging: true, debug: true) == "mc-staging.lubot.ai")
    }

    @Test func theseTestsRunInADebugBuildThatTakesTheServerItIsGiven() {
        #expect(ServerConfig.buildServer == nil)
    }

    @Test(arguments: ["mc-staging.lubot.ai", "mc.lubot.ai:8121", "mc.lubot.ai.example.org", "localhost",
                      "127.0.0.1", "kandor-works.example.org"])
    func aReleaseBuildRefusesEveryOtherServer(host: String) {
        #expect(throws: ServerConfig.Problem.wrongServer) {
            try ServerConfig.from(info(host: host), allowLocalHTTP: false, server: "mc.lubot.ai")
        }
    }

    @Test func aReleaseBuildTakesItsOwnServer() throws {
        let config = try ServerConfig.from(info(host: "mc.lubot.ai"), allowLocalHTTP: false, server: "mc.lubot.ai")

        #expect(config.base.absoluteString == "https://mc.lubot.ai")
    }

    @Test func aStagingBuildRefusesProduction() {
        #expect(throws: ServerConfig.Problem.wrongServer) {
            try ServerConfig.from(info(host: "mc.lubot.ai"), allowLocalHTTP: false, server: "mc-staging.lubot.ai")
        }
    }

    @Test func aBuildWithNoServerAddressStillSaysSoFirst() {
        #expect(throws: ServerConfig.Problem.noAddress) {
            try ServerConfig.from(info(host: ""), allowLocalHTTP: false, server: "mc.lubot.ai")
        }
    }
}
