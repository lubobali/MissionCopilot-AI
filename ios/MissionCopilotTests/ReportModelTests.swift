import Foundation
import Testing
@testable import MissionCopilot

/// The report page's model (#161, step 7.2.4): the Kandor report by code, the officer's removals, additions
/// and edits, each sentence's proof, and a draft saved only when every sentence has proof.
@MainActor
struct ReportModelTests {
    static let mission = PackDownloaderTests.mission

    static func loaded(finished: Bool = true) async throws -> (ReportModel, MissionStore) {
        let store: MissionStore
        if finished {
            store = try await ReportSourcesTests.finished().0  // finished as the app does: the flags stored
        } else {
            store = try await AskOpeningTests.store().0
        }
        let model = ReportModel(mission: mission, store: store, signer: SoftwareEvidenceSigner())
        await model.load()
        return (model, store)
    }

    /// #163, 7.3.6: the page shows its spinner until the report is built (off the main thread), then the report.
    @Test func theReportIsLoadingUntilItIsBuilt() async throws {
        let (store, _) = try await ReportSourcesTests.finished()
        let model = ReportModel(mission: Self.mission, store: store, signer: SoftwareEvidenceSigner())
        #expect(model.stage == .loading && model.lines.isEmpty)

        await model.load()

        #expect(model.stage == .ready && !model.lines.isEmpty)
    }

    @Test func theKandorReportOpensWithEverySentenceProven() async throws {
        let (model, _) = try await Self.loaded()

        #expect(model.stage == .ready)
        #expect(model.walkFinished)
        #expect(model.lines.count > 5 && model.lines.count <= 25, "short, like a real aide-memoire (#161, 7.2.7)")
        #expect(Set(model.lines.map(\.id)).count == model.lines.count, "each sentence once")
        #expect(model.unproven == 0 && model.canSave)
        #expect(model.summary == "\(model.lines.count) sentences, each with its proof")
        #expect(model.lines.contains { $0.text == "Your site walk: Has work on the Section 3 bridge started? No." })
        #expect(model.lines.contains { $0.text.hasPrefix("Red flag MC-01") })
        #expect(!model.lines.contains { $0.text.hasPrefix("Red flag MC-02") }, "a clear flag is not a finding")
    }

    @Test func eachSentenceShowsItsProof() async throws {
        let (model, _) = try await Self.loaded()
        let paid = try #require(model.lines.first { $0.text.hasPrefix("USD 8,500,000 paid to date") })

        let proof = model.proof(paid)

        #expect(proof.map(\.title) == ["Paid to date"])
        #expect(proof.first?.place == "Bank record · contracts")
    }

    /// The officer's sentence with a wrong number shows its reason and blocks the save; removing it unblocks.
    @Test func aSentenceWithNoProofBlocksTheSaveUntilRemoved() async throws {
        let (model, store) = try await Self.loaded()
        let action = try #require(model.pickable.first { $0.words.hasPrefix("Start the Section 3 bridge works") })

        #expect(!model.add(section: .findings, text: "The bridge works were not started by 30 Jul 2026.",
                           factIds: [action.id]))
        let added = try #require(model.lines.first { !$0.checked })
        #expect(added.section == .findings && added.reason == "The number 30 is not in the sources it cites.")
        #expect(model.summary.hasSuffix("· 1 with no proof"))
        model.save()
        #expect(model.problem == "Remove or fix the sentences with no proof before saving.")
        #expect(try store.latestDraft(in: Self.mission) == nil)

        model.remove(added.id)
        model.save()

        #expect(model.problem == nil)
        #expect(model.saved?.sentences.count == model.lines.count)
        #expect(try store.latestDraft(in: Self.mission) == model.saved)
    }

    /// An edit replaces the sentence with the officer's words, checked; a good one keeps its section.
    @Test func anEditIsCheckedLikeAnAddition() async throws {
        let (model, _) = try await Self.loaded()
        let line = try #require(model.lines.first { $0.section == .agreedActions })
        let action = try #require(model.pickable.first { $0.words.hasPrefix("Start the Section 3 bridge works") })

        #expect(model.edit(line.id, text: "The Section 3 bridge works were not started by the 31 Jul 2026 deadline.",
                           factIds: [action.id]))
        #expect(model.lines.contains { $0.section == .agreedActions && $0.text.hasSuffix("2026 deadline.") })
        #expect(!model.edit("no such sentence", text: "x", factIds: []))
    }

    /// An added sentence goes at the end of its own section, never into another.
    @Test func anAddedSentenceGoesAtTheEndOfItsSection() async throws {
        let (model, _) = try await Self.loaded()
        let action = try #require(model.pickable.first { $0.words.hasPrefix("Start the Section 3 bridge works") })

        model.add(section: .project, text: "The Section 3 bridge works were not started by the 31 Jul 2026 deadline.",
                  factIds: [action.id])

        let sections = model.lines.map(\.section)
        #expect(sections == sections.sorted { $0.order < $1.order })
        #expect(model.lines.last { $0.section == .project }?.text.hasSuffix("2026 deadline.") == true)
    }

    /// Before the walk is finished the report still opens, without what the walk saw.
    @Test func beforeTheFinishTheReportHasNoWalk() async throws {
        let (model, _) = try await Self.loaded(finished: false)

        #expect(model.stage == .ready && !model.walkFinished)
        #expect(!model.lines.contains { $0.text.hasPrefix("Your site walk") })
    }
}
