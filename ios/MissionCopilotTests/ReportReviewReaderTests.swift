import Foundation
import Testing
@testable import MissionCopilot

/// The phone reads the manager's decision (#193, step 193.2): one GET per report waiting for it; a send back is
/// kept and opens version 2; none yet (404) or an unreadable answer changes nothing.
@MainActor
struct ReportReviewReaderTests {
    static let mission = ReportModelTests.mission
    let harness = ReportSenderTests()

    @Test func aSendBackIsReadAndKept() async throws {
        let store = try await ReportVersionTests.received().store
        let body = #"{"version":1,"decision":"sent_back","note":"Check it.","reviewedAt":"2026-11-10T03:06:40Z"}"#
        let transport = FakeTransport(status: 200, body: Data(body.utf8))

        await ReportReviewReader(store: store).readAll(client: harness.client(transport))

        #expect(transport.sent.compactMap { $0.url?.path } == ["/v1/missions/\(Self.mission)/report/review"])
        #expect(try store.sentBack(in: Self.mission)?.note == "Check it.")
        #expect(try store.reportVersion(in: Self.mission) == 2)
    }

    @Test(arguments: [(404, ""), (200, "{}"), (200, #"{"version":1,"decision":"maybe","reviewedAt":"x"}"#)])
    func noDecisionOrAnUnreadableOneChangesNothing(status: Int, body: String) async throws {
        let store = try await ReportVersionTests.received().store

        let kept = await ReportReviewReader(store: store).read(mission: Self.mission,
                                                               client: harness.client(FakeTransport(
                                                                   status: status, body: Data(body.utf8))))

        #expect(kept == nil)
        #expect(try store.reportVersion(in: Self.mission) == 1)
        #expect(try store.awaitingReview() == [Self.mission])
    }

    @Test func nothingIsAskedWhenNoReportWaits() async throws {
        let (store, _) = try await ReportSourcesTests.finished()
        let transport = FakeTransport(status: 200, body: Data())

        await ReportReviewReader(store: store).readAll(client: harness.client(transport))

        #expect(transport.sent.isEmpty)
    }
}
