import Foundation
import Testing
@testable import MissionCopilot

/// Approving on the report page (#163, steps 7.3.3 and 7.3.4): only a ready report; one Face ID per approval; a
/// cancel or a failure stays as it was and says so; afterwards the report is the approved draft and is locked.
@MainActor
struct ReportModelApprovalTests {
    struct Ready {
        let model: ReportModel
        let store: MissionStore
        let signer: FakeApprovalSigner
    }

    static func ready(_ then: FakeApprovalSigner.Then = .sign) async throws -> Ready {
        let (store, _) = try await ReportSourcesTests.finished()
        let signer = FakeApprovalSigner(then)
        let model = ReportModel(mission: ReportModelTests.mission, store: store, signer: SoftwareEvidenceSigner(),
                                approvalSigner: signer)
        model.load()
        model.save()
        return Ready(model: model, store: store, signer: signer)
    }

    @Test func aReadyReportIsApprovedOnceAndLocked() async throws {
        let ready = try await Self.ready()
        let (model, store, signer) = (ready.model, ready.store, ready.signer)
        let lines = model.lines

        await model.approve()

        #expect(model.state == .approved && signer.signatures == 1)
        #expect(try store.approval(in: ReportModelTests.mission)?.draftId == model.saved?.id)
        #expect(model.approved?.approvedBy == AppSession.localProfile)
        model.remove(lines[0].id)
        model.add(section: .findings, text: "Anything.", factIds: [lines[0].factIds[0]])
        model.edit(lines[1].id, text: "Anything.", factIds: lines[1].factIds)
        model.save()
        await model.approve()
        #expect(model.lines == lines, "locked")
        #expect(signer.signatures == 1, "never asked again")
        #expect(try store.drafts(in: ReportModelTests.mission).count == 1)
    }

    @Test func aDraftIsNotApproved() async throws {
        let ready = try await Self.ready()
        let (model, store, signer) = (ready.model, ready.store, ready.signer)
        model.remove(model.lines[0].id)

        await model.approve()

        #expect(signer.signatures == 0 && model.state == .draft)
        #expect(model.problem == "Save the draft first, then approve it.")
        #expect(try store.approval(in: ReportModelTests.mission) == nil)
    }

    @Test func aCancelOrAFailureSaysSoAndApprovesNothing() async throws {
        let first = try await Self.ready(.cancel)
        let (cancelled, store) = (first.model, first.store)
        await cancelled.approve()
        #expect(cancelled.state == .ready && cancelled.problem == "Not approved: you cancelled.")
        #expect(try store.approval(in: ReportModelTests.mission) == nil)

        let failed = try await Self.ready(.fail).model
        await failed.approve()
        #expect(failed.state == .ready)
        #expect(failed.problem == "Not approved: Face ID or the passcode did not work. Try again.")
    }

    /// Reopened, the report is the approved draft as signed, even if records were added since.
    @Test func reopenedItIsTheApprovedDraft() async throws {
        let ready = try await Self.ready()
        let (model, store) = (ready.model, ready.store)
        await model.approve()
        let approvedLines = model.lines
        try store.addFacts([FactInput(name: "debrief.risk", value: #"{"byWhen":"","text":"Later note.","who":""}"#,
                                      unit: nil, sources: [FactSource(seq: 1, region: "later")],
                                      rule: MissionStore.debriefRule)], to: ReportModelTests.mission)

        let again = ReportModel(mission: ReportModelTests.mission, store: store, signer: SoftwareEvidenceSigner(),
                                approvalSigner: FakeApprovalSigner())
        again.load()

        #expect(again.state == .approved)
        #expect(again.lines.map(\.text) == approvedLines.map(\.text))
        #expect(!again.lines.contains { $0.text.contains("Later note") })
    }
}
