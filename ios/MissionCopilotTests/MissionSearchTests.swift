import Foundation
import Testing
@testable import MissionCopilot

/// Search (#145, step 6.7.2): keyword search (BM25) over the mission's sources, offline and the same every time.
/// Capitals and punctuation are ignored, letters split from digits, number words equal digits, common words
/// dropped, word endings trimmed; a few mission synonyms ("paid" is "disbursed" and "payments") and a small
/// French glossary let a French question find English sources. The answer key: the right source in the top 5.
struct MissionSearchTests {
    static let search = MissionSearch(sources: MissionSources.build(SourceInputs(packFiles: PackSectionsTests.files)))

    /// A Kandor question and the sources that answer it (any one of them in the top 5 passes).
    struct Case: CustomTestStringConvertible, Sendable {
        let question: String
        let answers: [String]
        var testDescription: String { question }
    }

    static let contracts = "pack:sections/contracts.json#/contracts/0"
    static let progress = "doc:documents/progress-report-2026-09.md#3"
    static let key: [Case] = [
        Case(question: "Was the Section 3 bridge started?",
             answers: [progress, "pack:sections/agreed-actions.json#/actions/0",
                       "pack:sections/milestones.json#/milestones/2"]),
        Case(question: "How much has been paid to the contractor?",
             answers: [contracts + "/payments#paid", "pack:sections/components.json#/components/0"]),
        Case(question: "What is the contract value?", answers: [contracts]),
        Case(question: "When was invoice 14 paid?", answers: [contracts + "/payments/5"]),
        Case(question: "What did the contractor promise in May?",
             answers: ["doc:documents/aide-memoire-2026-05.md#3", "pack:sections/agreed-actions.json#"]),
        Case(question: "How many km of road are built?",
             answers: [contracts + "/physicalProgress", progress, "pack:sections/results.json#/indicators/1"]),
        Case(question: "What is the overall risk rating?",
             answers: ["pack:sections/ratings.json#/overallRisk", "doc:documents/aide-memoire-2026-05.md#4"]),
        Case(question: "When does the contract end?", answers: [contracts + "/contractPeriod"]),
        Case(question: "Are there open grievances?", answers: ["pack:sections/safeguards.json#/grievances/1"]),
        Case(question: "Why is the contractor late?", answers: [progress]),
        Case(question: "Le pont de la section 3 a-t-il commencé ?",
             answers: [progress, "pack:sections/agreed-actions.json#/actions/0",
                       "pack:sections/milestones.json#/milestones/2"]),
        Case(question: "Quel est le montant du contrat ?", answers: [contracts]),
        Case(question: "Quand la facture 14 a-t-elle été payée ?", answers: [contracts + "/payments/5"]),
        Case(question: "Pourquoi l'entreprise est-elle en retard ?", answers: [progress])
    ]

    @Test func theAnswerKeyFindsTheRightSourceForAlmostEveryQuestion() {
        let missed = Self.key.filter { item in
            !Self.search.search(item.question).prefix(5).contains { item.answers.contains($0.source.id) }
        }

        #expect(missed.count <= 1, "missed: \(missed.map(\.question))")
    }

    @Test(arguments: key)
    func eachQuestionInTheKey(item: Case) {
        let top = Self.search.search(item.question).prefix(5).map(\.source.id)

        withKnownIssue("one miss is allowed by the key's pass mark", isIntermittent: true) {
            #expect(top.contains { item.answers.contains($0) }, "top 5: \(top)")
        }
    }

    @Test func aQuestionTheMissionCannotAnswerFindsNothing() {
        #expect(Self.search.search("Who won the election?").isEmpty)
        #expect(Self.search.search("   ").isEmpty)
    }

    @Test func theSourcesFoundStayWithinTheBudget() {
        let hits = Self.search.search("Section 3 bridge contractor payments invoice road km", limit: 8, budget: 600)

        #expect(hits.reduce(0) { $0 + $1.source.text.count } <= 600)
        #expect(!hits.isEmpty)
        #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })
    }

    @Test func wordsAreReadTheSameWayInQuestionsAndSources() {
        #expect(MissionSearch.terms("Invoice14 for $480,000!") == ["invoic", "14", "480000"])
        #expect(MissionSearch.terms("two weeks") == ["2", "week"])
        #expect(MissionSearch.terms("Was the bridge started?") == ["bridg", "start"])
        #expect(MissionSearch.terms("Le pont a-t-il commencé ?") == ["pont", "commenc"])
    }
}
