import Foundation
import Testing
@testable import DocumentLab

/// Every fact the model returns must be traceable to the scanned text (ADR 0009). These tests use the
/// answer key's printed lines and tables as the "scan", so they run anywhere without Vision.
struct GroundingTests {
    struct AnswerKey: Decodable {
        struct Page: Decodable { let lines: [String] }
        struct Table: Decodable { let headers: [String]; let rows: [[String]] }
        let facts: ExtractedFacts
        let pages: [String: Page]
        let tables: [String: Table]
    }

    static let key: AnswerKey = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/demo/scans/answer-key.json")
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(AnswerKey.self, from: Data(contentsOf: url))
    }()

    /// What the model sees: both pages' text, each table rendered as rows.
    static let source: String = ["invoice-14", "progress-report-2026-09"].map { name in
        let table = key.tables[name]!
        return (key.pages[name]!.lines.joined(separator: "\n")) + "\n"
            + TableText.render([[table.headers] + table.rows])
    }.joined(separator: "\n\n")

    private func with(_ change: (inout ExtractedFacts) -> Void) -> ExtractedFacts {
        var facts = Self.key.facts
        change(&facts)
        return facts
    }

    @Test func allEightTrueFactsAreGrounded() {
        let report = Grounding.check(Self.key.facts, in: Self.source)

        #expect(report.ungrounded.isEmpty)
        #expect(report.grounded.count == 8)
    }

    @Test func inventedAmountIsUngrounded() {
        // The free-text model in spike #13 wrote 8.5M as 85M.
        let report = Grounding.check(with { $0.cumulativePaid = 85_000_000 }, in: Self.source)

        #expect(report.ungrounded == ["cumulativePaid"])
    }

    @Test func partOfALargerNumberDoesNotCount() {
        let report = Grounding.check(with { $0.amountDue = 80_000; $0.invoiceNumber = "1" }, in: Self.source)

        #expect(Set(report.ungrounded) == ["amountDue", "invoiceNumber"])
    }

    @Test func bridgeCompletedIsNotGroundedByTheMilestoneNamedComplete() {
        // "Section 3 bridge complete" is a milestone NAME in the table, not the bridge's status.
        let report = Grounding.check(with { $0.bridgeStatus = "completed" }, in: Self.source)

        #expect(report.ungrounded == ["bridgeStatus"])
    }

    @Test func dateIsGroundedInItsPrintedFormOnly() {
        #expect(Grounding.check(Self.key.facts, in: Self.source).grounded["invoiceDate"] == "12 October 2026")
        #expect(Grounding.check(with { $0.invoiceDate = "2026-10-21" }, in: Self.source).ungrounded == ["invoiceDate"])
    }

    @Test func kmMustAppearAsPrinted() {
        let report = Grounding.check(with { $0.kmCompleted = 23 }, in: Self.source)

        #expect(report.ungrounded == ["kmCompleted"])
    }

    @Test func lineBreaksInTheScanDoNotBreakGrounding() {
        let broken = Self.source.replacingOccurrences(of: "USD 480,000", with: "USD\n480,000")

        #expect(Grounding.check(Self.key.facts, in: broken).ungrounded.isEmpty)
    }
}

struct TableTextTests {
    @Test func tableBecomesOneLinePerRow() {
        let text = TableText.render([[["Date", "Amount"], ["15 Feb 2025", "1,000,000"], ["30 Sep 2025", ""]]])

        #expect(text == "Date | Amount\n15 Feb 2025 | 1,000,000\n30 Sep 2025 | ")
    }
}

struct CrossCheckTests {
    private let rows = [["15 Feb 2025", "Advance payment", "1,000,000"], ["12 Oct 2026", "Invoice 14", "480,000"]]

    @Test func paymentsThatAddUpMatch() {
        #expect(CrossCheck.payments(rows, amountColumn: 2, claimedTotal: 1_480_000) == .matches(total: 1_480_000))
    }

    @Test func paymentsThatDoNotAddUpAreFlagged() {
        #expect(CrossCheck.payments(rows, amountColumn: 2, claimedTotal: 8_500_000)
            == .mismatch(tableTotal: 1_480_000, claimed: 8_500_000))
    }

    @Test func unreadableAmountIsReportedNotGuessed() {
        let garbled = [["15 Feb 2025", "Advance payment", "1,0O0,000"]]

        #expect(CrossCheck.payments(garbled, amountColumn: 2, claimedTotal: 1_000_000) == .unreadable(row: 0))
    }
}

struct MC01Tests {
    @Test func paidAheadOfBuiltRaisesTheFlag() throws {
        let result = try #require(RiskRules.mc01(GroundingTests.key.facts))

        #expect(result.financialPercent == 85 && result.physicalPercent == 50 && result.raised)
    }

    @Test func gapOfTwentyOrLessDoesNotRaise() throws {
        var facts = GroundingTests.key.facts
        facts.cumulativePaid = 7_000_000  // 70% paid vs 50% built: exactly 20 points

        #expect(try #require(RiskRules.mc01(facts)).raised == false)
    }

    @Test func zeroTotalsGiveNoResultInsteadOfACrash() {
        var facts = GroundingTests.key.facts
        facts.kmTotal = 0

        #expect(RiskRules.mc01(facts) == nil)
    }
}
