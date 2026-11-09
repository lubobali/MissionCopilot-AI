import Foundation
import Testing
@testable import MissionCopilot

/// The report's states (#163, step 7.3.1): needs proof, draft, ready, approved. Approve only when ready: every
/// sentence proven and exactly the saved draft on screen (an edit after saving makes it a draft again).
@MainActor
struct ReportStateTests {
    static let line = ReportLine(section: .findings, text: "Red flag MC-01: Payments are ahead.", factIds: ["f1"],
                                 checked: true)

    static func draft(_ lines: [ReportLine]) -> ReportDraft {
        ReportDraft(id: "d1", language: "en", createdAt: Date(timeIntervalSince1970: 0),
                    sentences: lines.enumerated().map { index, line in
                        Sentence(id: "s\(index)", section: line.section.rawValue, text: line.text,
                                 classification: .officialUseOnly, factIds: line.factIds)
                    })
    }

    @Test func eachStateFromTheLinesAndTheSavedDraft() {
        let unproven = ReportLine(section: .findings, text: "The road is good.", factIds: [], checked: false)
        let other = ReportLine(section: .findings, text: "Your site walk: Bridge started? No.", factIds: ["f2"],
                               checked: true)

        #expect(ReportState.of(lines: [Self.line, unproven], saved: nil, approved: false) == .needsProof(1))
        #expect(ReportState.of(lines: [Self.line], saved: nil, approved: false) == .draft)
        #expect(ReportState.of(lines: [], saved: nil, approved: false) == .draft, "nothing to approve")
        #expect(ReportState.of(lines: [Self.line], saved: Self.draft([Self.line]), approved: false) == .ready)
        #expect(ReportState.of(lines: [Self.line, other], saved: Self.draft([Self.line]), approved: false) == .draft,
                "a sentence added after saving")
        #expect(ReportState.of(lines: [other], saved: Self.draft([Self.line]), approved: false) == .draft)
        #expect(ReportState.of(lines: [Self.line], saved: Self.draft([Self.line]), approved: true) == .approved)
    }

    /// The same words citing other facts is a different sentence: save again before approving.
    @Test func otherFactsOrAnotherSectionIsADraftAgain() {
        let refacted = ReportLine(section: .findings, text: Self.line.text, factIds: ["f9"], checked: true)
        let moved = ReportLine(section: .nextSteps, text: Self.line.text, factIds: ["f1"], checked: true)

        #expect(ReportState.of(lines: [refacted], saved: Self.draft([Self.line]), approved: false) == .draft)
        #expect(ReportState.of(lines: [moved], saved: Self.draft([Self.line]), approved: false) == .draft)
        let reworded = ReportLine(section: .findings, text: "Red flag MC-01: Payments are well ahead.",
                                  factIds: ["f1"], checked: true)
        #expect(ReportState.of(lines: [reworded], saved: Self.draft([Self.line]), approved: false) == .draft,
                "other words over the same facts")
        #expect(ReportState.of(lines: [], saved: Self.draft([]), approved: false) == .draft, "an empty report")
    }

    /// In the app: opened, saved (ready), a sentence removed (draft), saved again (ready).
    @Test func savingMakesTheReportReadyAndAnEditUndoesIt() async throws {
        let (model, _) = try await ReportModelTests.loaded()
        #expect(model.state == .draft && !model.canApprove)

        model.save()
        #expect(model.state == .ready && model.canApprove)

        let first = try #require(model.lines.first)
        model.remove(first.id)
        #expect(model.state == .draft && !model.canApprove)

        model.save()
        #expect(model.state == .ready)
    }

    /// Reopened after a save, the same records give the same report: still ready.
    @Test func reopenedAfterASaveItIsStillReady() async throws {
        let (model, store) = try await ReportModelTests.loaded()
        model.save()

        let again = ReportModel(mission: ReportModelTests.mission, store: store, signer: SoftwareEvidenceSigner())
        await again.load()

        #expect(again.state == .ready)
    }
}
