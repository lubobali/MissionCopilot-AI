import Foundation
import Testing
@testable import MissionCopilot

/// The connection watch reports the phone's state as soon as it starts (#92), so the mission list knows
/// whether a paused download can go on; online or not depends on the machine running the test.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct NetworkWatchTests {
    @Test func theCurrentStateArrivesSoonAfterStarting() async throws {
        let watch = NetworkWatch()
        let reports = AsyncStream<Bool>.makeStream()

        watch.start { online in reports.continuation.yield(online) }
        defer { watch.stop() }

        var first: Bool?
        for await online in reports.stream {
            first = online
            break
        }
        #expect(first != nil)
    }
}
