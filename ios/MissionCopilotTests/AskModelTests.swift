import Foundation
import Testing
@testable import MissionCopilot

/// The Ask page, PR 1 (#145, step 6.7.3): a question finds the mission's sources, each shown with its title,
/// its kind and where it came from in words. No model yet: the sources themselves are the answer for now.
@MainActor
struct AskModelTests {
    static func model() -> AskModel {
        AskModel(sources: MissionSources.build(SourceInputs(packFiles: PackSectionsTests.files)))
    }

    @Test func aQuestionShowsTheSourcesFoundBestFirst() throws {
        let model = Self.model()
        model.question = "When was invoice 14 paid?"

        model.ask()

        #expect(model.state == .found)
        let first = try #require(model.results.first)
        #expect(first.title == "Contracts › contracts 1 › payments 6")
        #expect(first.kind == "Bank record")
        #expect(first.place == "contracts.json · /contracts/0/payments/5")
        #expect(first.text.contains("reference: Invoice 14"))
        #expect(model.results.count <= 5)
    }

    @Test func eachKindOfSourceSaysWhereItCameFrom() {
        let words = [
            AskModel.place(.pack(PackCitation(path: "sections/contracts.json", sha256: "x", pointer: "/contracts/0"))),
            AskModel.place(.document(path: "documents/aide-memoire-2026-05.md", paragraph: 3)),
            AskModel.place(.fact(id: "f", sources: [FactSource(seq: 4, region: nil)])),
            AskModel.place(.walk(question: "bridge_started")),
            AskModel.place(.redFlag(rule: "MC-01"))
        ]

        #expect(words == ["contracts.json · /contracts/0", "aide-memoire-2026-05.md · paragraph 3",
                          "Evidence 4, confirmed by the officer", "Site walk · bridge_started", "Red flag rule MC-01"])
        #expect(MissionSource.Kind.allCases.map(AskModel.kindWords)
                == ["Bank record", "Document", "Confirmed fact", "Debrief note", "Site walk", "Red flag"])
    }

    @Test func aQuestionTheMissionCannotAnswerSaysSo() {
        let model = Self.model()
        model.question = "Who won the election?"

        model.ask()

        #expect(model.state == .nothingFound)
        #expect(model.results.isEmpty)
        #expect(AskModel.nothingFound == "Nothing in this mission's data matches this question.")
    }

    @Test func anEmptyQuestionDoesNothing() {
        let model = Self.model()
        model.question = "  "

        model.ask()

        #expect(model.state == .waiting)
        #expect(!model.canAsk)
    }

    @Test func theCardSaysHowManySourcesTheMissionHas() {
        #expect(Self.model().summary == "51 sources on this iPhone")
        #expect(AskModel(sources: []).summary == "No mission data on this iPhone yet")
    }
}
