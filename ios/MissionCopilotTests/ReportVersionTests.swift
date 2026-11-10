import Foundation
import Testing
@testable import MissionCopilot

/// Send back and version 2 on the phone (#193, steps 193.1-193.3; server #178): a manager's decision on the
/// version this phone sent is kept, once; a send back opens the next version (the sent draft is history, a new
/// one is saved and approved with Face ID, then queued with a new key); an endorsement is final; an older or an
/// unsent version's decision changes nothing.
@MainActor
struct ReportVersionTests {
    static let mission = ReportModelTests.mission
    static let back = ReportReview(version: 1, decision: .sentBack, note: "Check the bridge numbers.",
                                   reviewedAt: Date(timeIntervalSince1970: 1_794_300_000))

    /// An approved report, queued and received by the server.
    static func received() async throws -> ReportModelApprovalTests.Ready {
        let ready = try await ReportModelApprovalTests.ready()
        await ready.model.approve()
        try ready.store.queueReport(in: mission)
        try ready.store.keepReceipt(batchId: "batch-1", receivedAt: Date(timeIntervalSince1970: 1_794_270_000),
                                    in: mission)
        return ready
    }

    @Test func aReceivedReportWaitsForItsDecision() async throws {
        let store = try await Self.received().store
        #expect(try !store.needsResponse(in: Self.mission), "nothing sent back: nothing to answer")

        #expect(try store.reportVersion(in: Self.mission) == 1)
        #expect(try store.awaitingReview() == [Self.mission])
        #expect(try store.review(in: Self.mission) == nil)
    }

    @Test func aSendBackOpensTheNextVersion() async throws {
        let store = try await Self.received().store
        let first = try #require(try store.approval(in: Self.mission))

        #expect(try store.keepReview(Self.back, in: Self.mission))

        #expect(try store.reportVersion(in: Self.mission) == 2)
        #expect(try store.approval(in: Self.mission) == nil, "version 2 is not approved yet")
        #expect(try store.outbox(in: Self.mission) == nil && store.receipt(in: Self.mission) == nil)
        #expect(try store.queuedReports().isEmpty && store.awaitingReview().isEmpty)
        #expect(try store.sentBack(in: Self.mission) == Self.back)
        #expect(try store.isApprovedDraft(first.draftId), "version 1's approval stays as history")
        #expect(try store.needsResponse(in: Self.mission))
    }

    @Test func onlyTheSentVersionsDecisionIsKeptAndOnlyOnce() async throws {
        let approved = try await ReportModelApprovalTests.ready()
        await approved.model.approve()
        #expect(try !approved.store.keepReview(Self.back, in: Self.mission), "not received yet: nothing kept")

        let store = try await Self.received().store
        let later = ReportReview(version: 2, decision: .endorsed, note: nil, reviewedAt: Date())
        #expect(try !store.keepReview(later, in: Self.mission), "a version this phone did not send")
        #expect(try store.keepReview(Self.back, in: Self.mission))
        #expect(try !store.keepReview(Self.back, in: Self.mission), "once")
        #expect(throws: (any Error).self) {
            try store.store.write { try $0.execute(sql: "UPDATE report_review SET note = 'changed'") }
        }
    }

    @Test func version2IsANewDraftApprovedWithFaceIDAndQueuedWithANewKey() async throws {
        let ready = try await Self.received()
        let (store, signer) = (ready.store, ready.signer)
        let firstKey = try #require(try store.outbox(in: Self.mission)).idempotencyKey
        let firstDraft = try #require(try store.approval(in: Self.mission)).draftId
        try store.keepReview(Self.back, in: Self.mission)
        let model = ReportModel(mission: Self.mission, store: store, signer: SoftwareEvidenceSigner(),
                                approvalSigner: signer)
        await model.load()

        #expect(model.state == .draft, "the sent draft is history: save a new one first")
        #expect(model.managerWords?.contains("Check the bridge numbers.") == true)
        #expect(model.managerWords?.contains("send version 2") == true)
        #expect(model.lines.map(\.text) == (try store.latestDraft(in: Self.mission))?.sentences.map(\.text))
        await model.approve()
        #expect(model.approved == nil, "the old draft is never approved again")

        model.save()
        await model.approve()

        let second = try #require(model.approved)
        #expect(second.draftId != firstDraft && model.state == .approved)
        let queued = try store.queueReport(in: Self.mission)
        #expect(queued.idempotencyKey != firstKey && queued.draftId == second.draftId)
        #expect(try store.queuedReports() == [Self.mission])
        #expect(model.managerWords == nil, "approved again: the note has done its job")
        #expect(try store.needsResponse(in: Self.mission), "#195: still to send")
        try store.keepReceipt(batchId: "batch-2", receivedAt: Date(), in: Self.mission)
        #expect(try !store.needsResponse(in: Self.mission), "version 2 received: nothing more to do")
    }

    @Test func theStoreNeverApprovesASentBackDraftAgain() async throws {
        let ready = try await Self.received()
        let store = ready.store
        try store.keepReview(Self.back, in: Self.mission)
        let old = try #require(try store.latestDraft(in: Self.mission))
        let now = Date()
        let signed = try await ReportApproval.sign(draft: old, mission: Self.mission, by: AppSession.localProfile,
                                                   at: now, signer: ready.signer)

        #expect(throws: MissionStore.NotTheLatestDraft()) {
            try store.approve(signed, draft: old, by: AppSession.localProfile, at: now, in: Self.mission)
        }
    }

    @Test func anEndorsementIsFinal() async throws {
        let store = try await Self.received().store
        let endorsed = ReportReview(version: 1, decision: .endorsed, note: nil,
                                    reviewedAt: Date(timeIntervalSince1970: 1_794_300_000))

        #expect(try store.keepReview(endorsed, in: Self.mission))

        #expect(try store.reportVersion(in: Self.mission) == 1 && store.review(in: Self.mission) == endorsed)
        #expect(try store.awaitingReview().isEmpty)
        #expect(throws: MissionStore.ReportApproved.self) {
            try store.saveDraft([], language: .english, in: Self.mission)
        }
        let model = ReportModel(mission: Self.mission, store: store, signer: SoftwareEvidenceSigner())
        await model.load()
        #expect(model.managerWords?.hasPrefix("Endorsed by your manager") == true)
    }
}
