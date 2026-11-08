import Foundation
import Testing
@testable import MissionCopilot

/// Answer lines written by code (#145, step 6.7.11, decided after Lubo's iPhone tests): every record becomes
/// one short line a person can act on, with the record it cites. Payments, the total, agreed actions,
/// milestones, the walk, red flags, scans and debrief notes have their own words; any other pack record reads
/// "Title: field; field", so a pack from any sector still answers. English and French.
struct AnswerLinesTests {
    static let sources = MissionSources.build(SourceInputs(packFiles: PackSectionsTests.files))
    static let invoice14 = "pack:sections/contracts.json#/contracts/0/payments/5"
    static let paid = "pack:sections/contracts.json#/contracts/0/payments#paid"
    static let action = "pack:sections/agreed-actions.json#/actions/0"
    static let milestone = "pack:sections/milestones.json#/milestones/2"

    static func source(_ id: String) throws -> MissionSource {
        try #require(sources.first { $0.id == id })
    }

    static func line(_ id: String, _ language: AnswerLanguage = .english, question: String = "") throws -> String {
        AnswerLines.line(try source(id), question: question, language: language).text
    }

    @Test func paymentsAndTheTotalAreOneShortLine() throws {
        #expect(try Self.line(Self.invoice14) == "Invoice 14: USD 480,000, paid 12 Oct 2026.")
        #expect(try Self.line(Self.paid) == "USD 8,500,000 paid to date (the sum of 6 payments).")
        #expect(try Self.line(Self.invoice14, .french) == "Invoice 14 : USD 480,000, payée le 12 Oct 2026.")
        #expect(try Self.line(Self.paid, .french) == "USD 8,500,000 payés à ce jour (somme de 6 paiements).")
    }

    @Test func actionsAndMilestonesSayWhereTheyStand() throws {
        #expect(try Self.line(Self.action)
                == "Start the Section 3 bridge works: not started, deadline 31 Jul 2026, Contractor.")
        #expect(try Self.line(Self.action, .french)
                == "Start the Section 3 bridge works : pas commencé, échéance 31 Jul 2026, Contractor.")
        #expect(try Self.line(Self.milestone) == "Section 3 bridge complete: not met, due 30 Sep 2026.")
        #expect(try Self.line("pack:sections/milestones.json#/milestones/1")
                == "Sections 1 and 2 paved: met 20 Jul 2026.")
    }

    @Test func anyOtherPackRecordReadsAsItsTitleAndFields() throws {
        #expect(try Self.line("pack:sections/ratings.json#/overallRisk")
                == "Ratings · Overall risk: Current: High; Previous: Substantial.")
        #expect(try Self.line("pack:sections/contracts.json#/contracts/0/contractPeriod")
                == "Contracts · Contract period: End: 31 Dec 2026; Start: 15 Jan 2025.")
    }

    @Test func theWalkFlagsScansAndNotesSayWhoseTheyAre() {
        let walk = MissionSource(id: "walk:bridge_started", kind: .walkAnswer,
                                 title: "Has work on the Section 3 bridge started?",
                                 text: "Has work on the Section 3 bridge started? yes", origin: .walk(question: "x"))
        let check = MissionSource(id: "walk:action-53f6e638bcf6", kind: .walkAnswer,
                                  title: "Agreed action: Start the Section 3 bridge works", text: "Seen: done.",
                                  origin: .walk(question: "action-53f6e638bcf6"))
        let flag = MissionSource(id: "flag:MC-02:0", kind: .redFlag, title: "The same invoice paid twice",
                                 text: "No invoice reference or amount appears twice.", origin: .redFlag(rule: "MC-02"))
        let scan = MissionSources.fact(Fact(id: "f", name: "invoiceDate", value: "2026-10-12", unit: nil,
                                            rule: MissionStore.scanRule, classification: .officialUseOnly,
                                            sources: [FactSource(seq: 1, region: nil)]))
        let note = MissionSource(id: "fact:n", kind: .note, title: "Debrief note · Action",
                                 text: "Contractor sends a new work plan. Who: contractor.",
                                 origin: .fact(id: "n", sources: []))

        #expect(AnswerLines.line(walk).text == "Your site walk: Has work on the Section 3 bridge started? Yes.")
        #expect(AnswerLines.line(check).text == "Your site walk: Start the Section 3 bridge works, seen done.")
        #expect(AnswerLines.line(flag).text == "Red flag MC-02: No invoice reference or amount appears twice.")
        #expect(AnswerLines.line(scan).text == "From your scanned invoice: Invoice date: 2026-10-12.")
        #expect(AnswerLines.line(note).text == "From your debrief: Contractor sends a new work plan. Who: contractor.")
        #expect(AnswerLines.line(walk, language: .french).text
                == "Votre visite : Has work on the Section 3 bridge started? Yes.")
    }

    /// A document paragraph gives its one sentence that best fits the question, word for word.
    @Test func aDocumentGivesItsBestSentenceWordForWord() throws {
        let line = try Self.line("doc:documents/aide-memoire-2026-05.md#3",
                                 question: "What did the contractor promise?")

        #expect(line == "Aide memoire, May 2026: \"Previous mission (May 2026): the contractor committed to start the "
                + "Section 3 bridge by July 2026 and to submit a revised work plan.\"")
    }

    @Test func eachLineCitesItsRecord() throws {
        #expect(AnswerLines.line(try Self.source(Self.invoice14)).sources == [Self.invoice14])
    }

    /// The code's own words hold no number or month that their record does not (checked the way a model's
    /// sentence is). Every English line of the Kandor pack, against its own record. (A line may name a
    /// milestone "Section 3 bridge complete": names are not checked as statuses here.)
    @Test func everyLineOfThePackHoldsOnlyItsRecordsNumbersAndMonths() {
        let failing = Self.sources.compactMap { source -> String? in
            let line = AnswerLines.line(source)
            let reason = AnswerCheck.reason(line.text, cites: [source.id], found: [source])
            let counted = reason.map { $0.hasPrefix("The number") || $0.hasPrefix("The month") } ?? false
            return counted ? "\(source.id): \(reason ?? "")" : nil
        }

        #expect(failing.isEmpty, "\(failing)")
    }

    @Test func theLanguageFollowsTheQuestion() {
        #expect(AnswerLanguage(question: "Quand la facture 14 a-t-elle été payée ?") == .french)
        #expect(AnswerLanguage(question: "When was invoice 14 paid?") == .english)
    }
}
