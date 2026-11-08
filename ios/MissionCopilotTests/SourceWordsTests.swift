import Foundation
import Testing
@testable import MissionCopilot

/// Sources in words (#145, step 6.7.3, after Lubo's first look on the iPhone): a title a person would say,
/// money with commas and its currency, dates in words, a table as rows, never a JSON Pointer or a hash, never
/// the same words twice; rows of one kind (the six payments) grouped into one card.
struct SourceWordsTests {
    static let sources = MissionSources.build(SourceInputs(packFiles: PackSectionsTests.files))

    static func source(_ id: String) throws -> MissionSource {
        try #require(sources.first { $0.id == id })
    }

    @Test func aPaymentReadsLikeAPerson() throws {
        let card = SourceWords.card(try Self.source("pack:sections/contracts.json#/contracts/0/payments/1"))

        #expect(card.title == "Payment · Invoice 6")
        #expect(card.lines == ["Amount: USD 1,500,000", "Date: 30 Sep 2025"])
        #expect(card.place == "Bank record · contracts")
    }

    @Test func otherBankRecordsUseTheirOwnNames() throws {
        let contract = SourceWords.card(try Self.source("pack:sections/contracts.json#/contracts/0"))
        let action = SourceWords.card(try Self.source("pack:sections/agreed-actions.json#/actions/0"))
        let risk = SourceWords.card(try Self.source("pack:sections/ratings.json#/overallRisk"))
        let paid = SourceWords.card(try Self.source("pack:sections/contracts.json#/contracts/0/payments#paid"))

        #expect(contract.title == "Contract · Upgrading of the 64 km Package 1 road")
        #expect(contract.lines.contains("Contract value: USD 10,000,000"))
        #expect(action.title == "Agreed action · Start the Section 3 bridge works")
        #expect(action.lines == ["Deadline: 31 Jul 2026", "Responsible: Contractor", "Status: Not started"])
        #expect(risk.title == "Ratings · Overall risk")
        #expect(risk.lines == ["Current: High", "Previous: Substantial"])
        #expect(paid.title == "Paid to date")
        #expect(paid.lines == ["USD 8,500,000, the sum of the pack's 6 payments, added by the app"])
    }

    @Test func aDocumentTableBecomesRowsAndBulletsLoseTheirMarks() throws {
        let table = SourceWords.card(try Self.source("doc:documents/aide-memoire-2026-05.md#6"))
        let report = SourceWords.card(try Self.source("doc:documents/progress-report-2026-09.md#3"))

        #expect(table.title == "Aide memoire, May 2026 · paragraph 6")
        #expect(table.lines.first == "Start the Section 3 bridge works · Contractor · 31 Jul 2026 · Not started")
        #expect(!table.lines.contains { $0.contains("---") || $0.contains("|") })
        #expect(report.lines.contains("Section 3 bridge: not started"))
        #expect(report.title == "Progress report, Sep 2026 · paragraph 3")
        #expect(report.place == "Document in the mission pack")
    }

    @Test func walkAnswersAndChecksSayItOnce() {
        let answer = MissionSource(id: "walk:bridge_started", kind: .walkAnswer,
                                   title: "Has work on the Section 3 bridge started?",
                                   text: "Has work on the Section 3 bridge started? yes",
                                   origin: .walk(question: "bridge_started"))
        let check = MissionSource(id: "walk:action-53f6e638bcf6", kind: .walkAnswer,
                                  title: "Agreed action: Start the Section 3 bridge works",
                                  text: "Seen: done.", origin: .walk(question: "action-53f6e638bcf6"))

        #expect(SourceWords.card(answer) == SourceCardWords(title: "Has work on the Section 3 bridge started?",
                                                            lines: ["Yes"], place: "Your site walk"))
        #expect(SourceWords.card(check).title == "Agreed action: Start the Section 3 bridge works")
        #expect(SourceWords.card(check).lines == ["Seen: done."])
        #expect(!SourceWords.card(check).place.contains("53f6"))
    }

    @Test func rowsOfOneKindAreGroupedIntoOneCard() throws {
        let search = MissionSearch(sources: Self.sources)

        let cards = SourceWords.group(search.search("How much has been paid?", limit: 8, budget: 6_000))

        let payments = try #require(cards.first { $0.title.hasPrefix("Payments") })
        #expect(payments.title == "Payments (6)")
        #expect(payments.lines.contains("Invoice 14 · USD 480,000 · 12 Oct 2026"))
        #expect(cards.filter { $0.title.hasPrefix("Payment ·") }.isEmpty)
    }

    @Test func numbersAndDatesKeepTheirMeaning() {
        #expect(SourceWords.value("1500000", key: "amount") == "USD 1,500,000")
        #expect(SourceWords.value("26000", key: "actual current") == "26,000")
        #expect(SourceWords.value("2025-09-30", key: "date") == "30 Sep 2025")
        #expect(SourceWords.value("KRRP-P1", key: "id") == "KRRP-P1")
        #expect(SourceWords.value("12000000", key: "budget") == "USD 12,000,000")
    }

    /// Found on the iPhone: "Section 3 bridge: not_started" and the demo's fictional-data note in an answer.
    @Test func codesBecomeWordsAndTheDemoNoteIsLeftOut() throws {
        let bridge = Fact(id: "f", name: "bridgeStatus", value: "not_started", unit: nil, rule: MissionStore.scanRule,
                          classification: .officialUseOnly, sources: [FactSource(seq: 1, region: nil)])
        let project = SourceWords.card(try Self.source("pack:sections/project.json#"))

        #expect(SourceWords.card(MissionSources.fact(bridge)).lines == ["Section 3 bridge: Not started"])
        #expect(!project.lines.contains { $0.contains("Fictional") })
        #expect(project.lines.contains("Budget: USD 12,000,000"))
    }
}
