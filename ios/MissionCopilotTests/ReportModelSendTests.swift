import Foundation
import Testing
@testable import MissionCopilot

/// Sending from the report page (#173, step 8.3.3): only once approved; the review shows exactly what goes;
/// sending queues the report (one stable key) and says what happened in plain words; a page opened later
/// shows the receipt, or that it is waiting for a connection.
@MainActor
struct ReportModelSendTests {
    static let mission = ReportModelTests.mission

    static func approved(send: @escaping @Sendable (String) async -> ReportSender.Outcome) async throws
        -> (ReportModel, MissionStore) {
        let (store, _) = try await ReportSourcesTests.finished()
        let model = ReportModel(mission: mission, store: store, signer: SoftwareEvidenceSigner(),
                                approvalSigner: FakeApprovalSigner(), send: send)
        await model.load()
        model.save()
        await model.approve()
        return (model, store)
    }

    @Test func theReviewShowsExactlyWhatGoes() async throws {
        let (model, store) = try await Self.approved { _ in .notQueued }

        let counts = try #require(model.sendCounts)

        #expect(counts == (try SyncBatchBuilder.build(in: Self.mission, store: store)).counts)
        #expect(counts.sentences == model.lines.count && counts.facts > 0 && counts.evidence > 0)
        #expect(model.sendReview.hasPrefix("\(counts.sentences) sentences, \(counts.facts) facts"))
    }

    @Test func sendingQueuesTheReportAndSaysItWasReceived() async throws {
        let when = Date(timeIntervalSince1970: 1_794_272_400)
        let (model, store) = try await Self.approved { _ in .received(when) }

        await model.send()

        #expect(try store.outbox(in: Self.mission) != nil, "queued, with its one key")
        #expect(model.sendOutcome == .received(when) && !model.sending)
        #expect(model.sendWords == "Received by the server \(when.formatted(date: .abbreviated, time: .shortened)).")
    }

    @Test func offlineItSaysItWaitsAndAPageOpenedLaterStillSaysSo() async throws {
        let (model, store) = try await Self.approved { _ in .waiting }

        await model.send()
        #expect(model.sendWords == "Waiting for a connection. It goes by itself when this iPhone is online.")

        let later = ReportModel(mission: Self.mission, store: store, signer: SoftwareEvidenceSigner())
        await later.load()
        #expect(later.sendOutcome == .waiting)
    }

    @Test func aPageOpenedAfterTheReceiptShowsIt() async throws {
        let (model, store) = try await Self.approved { _ in .notQueued }
        try store.queueReport(in: Self.mission)
        let when = Date(timeIntervalSince1970: 1_794_272_400)
        try store.keepReceipt(batchId: "b", receivedAt: when, in: Self.mission)

        await model.load()

        #expect(model.sendOutcome == .received(when))
    }

    @Test func aReportNotApprovedCannotBeSent() async throws {
        let (store, _) = try await ReportSourcesTests.finished()
        let model = ReportModel(mission: Self.mission, store: store, signer: SoftwareEvidenceSigner(),
                                send: { _ in .received(Date()) })
        await model.load()

        await model.send()

        #expect(model.sendCounts == nil && model.sendOutcome == nil)
        #expect(try store.outbox(in: Self.mission) == nil)
    }

    @Test func aRefusalIsSaid() async throws {
        let (model, _) = try await Self.approved { _ in .refused(ReportSender.refusedWords) }

        await model.send()

        #expect(model.sendWords == ReportSender.refusedWords)
    }
}
