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

    @Test(arguments: [ServerConfig.Problem.noAddress, .badAddress, .wrongServer, .noKeys, .badKey])
    func aBuildWithoutAUsableServerSaysWhatIsMissing(problem: ServerConfig.Problem) {
        #expect(!Connection.text(problem).isEmpty)
    }

    @Test func eachProblemSaysSomethingDifferent() {
        let problems: [ServerConfig.Problem] = [.noAddress, .badAddress, .wrongServer, .noKeys, .badKey]

        #expect(Set(problems.map(Connection.text)).count == problems.count)
    }
}
