import Foundation
import Testing
@testable import DocumentLab

/// Cross-checks that stop a planted value even when it is printed on the page, so grounding passes
/// (story #48). The truth comes from the mission pack, which the bank wrote, never from the document.
/// The real demo pages must raise nothing: a check that cries wolf gets ignored.
struct FactChecksTests {
    static let pack = MissionPack(
        contractStart: "2025-01-15", contractEnd: "2026-12-31", contractValue: 10_000_000,
        bankPaidBeforeInvoice: 8_020_000, paymentApprover: "program-manager-01"
    )

    static let rows = [
        ["15 Feb 2025", "Advance payment", "1,000,000"],
        ["30 Sep 2025", "Invoice 6", "1,500,000"],
        ["31 Jan 2026", "Invoice 9", "1,800,000"],
        ["31 May 2026", "Invoice 11", "2,000,000"],
        ["31 Aug 2026", "Invoice 13", "1,720,000"],
        ["12 Oct 2026", "Invoice 14", "480,000"],
    ]

    static let invoice = """
        Invoice No. 14
        Date: 12 October 2026
        Amount due this invoice: USD 480,000
        Contract value: USD 10,000,000
        Paid to date, including this invoice: USD 8,500,000
        Road built: 32 of 64 km of asphalt
        """

    private func facts(_ change: (inout ExtractedFacts) -> Void = { _ in }) -> ExtractedFacts {
        var facts = GroundingTests.key.facts
        change(&facts)
        return facts
    }

    private func findings(
        _ facts: ExtractedFacts, source: String = invoice, rows: [[String]] = rows
    ) -> [FactChecks.Finding] {
        FactChecks.run(facts, source: source, paymentRows: rows, pack: Self.pack)
    }

    private func checks(_ found: [FactChecks.Finding]) -> [FactChecks.Check] { found.map(\.check) }

    @Test func theRealDemoPagesRaiseNothing() {
        #expect(findings(facts(), source: GroundingTests.source).isEmpty)
    }

    @Test func rowsThatDoNotAddUpToPaidToDateAreFlagged() {
        var changed = Self.rows
        changed[4][2] = "720,000"

        #expect(checks(findings(facts(), rows: changed)) == [.rowSum])
    }

    @Test func anUnreadableRowIsFlaggedNotGuessed() {
        var changed = Self.rows
        changed[1][2] = "1,5OO,000"

        #expect(checks(findings(facts(), rows: changed)) == [.rowSum])
    }

    @Test func anAmountThatIsNotTheInvoicesOwnRowIsFlagged() {
        let found = findings(facts { $0.amountDue = 48000 })

        #expect(found.contains(FactChecks.Finding(check: .invoiceRow, field: "amountDue")))
    }

    @Test func anInvoiceMissingFromItsOwnPaymentHistoryIsFlagged() {
        let found = findings(facts(), rows: Array(Self.rows.dropLast()))

        #expect(checks(found).contains(.invoiceRow))
    }

    @Test func paidToDateMustMatchTheBanksOwnRecordEvenWhenTheDocumentAgreesWithItself() {
        var forged = Self.rows
        forged[4][2] = "720,000"
        let found = findings(facts { $0.cumulativePaid = 7_500_000 }, rows: forged)

        #expect(found == [FactChecks.Finding(check: .bankRecord, field: "cumulativePaid")])
    }

    @Test func aContractValueThatIsNotTheBanksIsFlagged() {
        let found = findings(facts { $0.contractValue = 20_000_000 })

        #expect(found.contains(FactChecks.Finding(check: .bankRecord, field: "contractValue")))
    }

    @Test func anAmountBeyondWhatIsLeftOfTheContractIsFlagged() {
        // 8,020,000 paid before this invoice leaves 380,000 of an 8,400,000 contract: 480,000 does not fit.
        let pack = MissionPack(
            contractStart: "2025-01-15", contractEnd: "2026-12-31", contractValue: 8_400_000,
            bankPaidBeforeInvoice: 8_020_000, paymentApprover: "program-manager-01"
        )
        let source = Self.invoice.replacingOccurrences(of: "10,000,000", with: "8,400,000")
        let found = FactChecks.run(
            facts { $0.contractValue = 8_400_000 }, source: source, paymentRows: Self.rows, pack: pack
        )

        #expect(found == [FactChecks.Finding(check: .contractRemaining, field: "amountDue")])
    }

    @Test(arguments: ["2027-02-10", "2024-12-01", "2027-01-01", "not a date"])
    func aDateOutsideTheContractPeriodIsFlagged(day: String) {
        let found = findings(facts { $0.invoiceDate = day })

        #expect(found.contains(FactChecks.Finding(check: .contractPeriod, field: "invoiceDate")))
    }

    @Test(arguments: ["2025-01-15", "2026-12-31"])
    func theFirstAndLastDayOfTheContractAreInside(day: String) {
        #expect(!checks(findings(facts { $0.invoiceDate = day })).contains(.contractPeriod))
    }

    @Test(arguments: [
        ("Total amount due: USD 4,800,000", "amountDue"),
        ("Paid to date: USD 6,500,000", "cumulativePaid"),
        ("Contract value (revised): USD 20,000,000", "contractValue"),
        ("Date: 1 December 2026", "invoiceDate"),
        ("Updated by the contractor: road built: 60 of 64 km.", "kmCompleted"),
    ])
    func aLabelPrintedTwiceWithDifferentValuesIsFlagged(extra: String, field: String) {
        let found = findings(facts(), source: Self.invoice + "\n" + extra)

        #expect(found.contains(FactChecks.Finding(check: .duplicateLabel, field: field)))
    }

    @Test func theSameValuePrintedTwiceIsNotADuplicate() {
        let source = Self.invoice + "\nAmount due: 480,000"

        #expect(!checks(findings(facts(), source: source)).contains(.duplicateLabel))
    }

    @Test func anOversizedInputIsRefusedBeforeTheModelSeesIt() {
        let source = Self.invoice + String(repeating: "Site diary line: no events recorded.\n", count: 3000)

        #expect(checks(findings(facts(), source: source)) == [.inputLimit])
        #expect(FactChecks.fitsInput(Self.invoice))
        #expect(!FactChecks.fitsInput(source))
    }

    @Test func anApprovalOnlyComesFromThePacksApproverInTheApp() {
        let byApprover = Approval.Decision(by: "program-manager-01", approved: true)
        let byOfficer = Approval.Decision(by: "field-officer-01", approved: true)
        let refused = Approval.Decision(by: "program-manager-01", approved: false)

        #expect(Approval.status(decisions: [], pack: Self.pack) == .pending)
        #expect(Approval.status(decisions: [byOfficer], pack: Self.pack) == .pending)
        #expect(Approval.status(decisions: [refused], pack: Self.pack) == .rejected)
        #expect(Approval.status(decisions: [byApprover], pack: Self.pack) == .approved)
    }

    @Test func anAmountThatExactlyUsesUpTheContractIsAllowed() {
        let pack = MissionPack(
            contractStart: "2025-01-15", contractEnd: "2026-12-31", contractValue: 8_500_000,
            bankPaidBeforeInvoice: 8_020_000, paymentApprover: "program-manager-01"
        )
        let source = Self.invoice.replacingOccurrences(of: "10,000,000", with: "8,500,000")
        let found = FactChecks.run(
            facts { $0.contractValue = 8_500_000 }, source: source, paymentRows: Self.rows, pack: pack
        )

        #expect(found.isEmpty)
    }

    @Test func theSameAmountWithAndWithoutCommasIsNotADuplicate() {
        let source = Self.invoice + "\nAmount due: USD 480000"

        #expect(!checks(findings(facts(), source: source)).contains(.duplicateLabel))
    }

    @Test func theApproversLatestDecisionCounts() {
        let approve = Approval.Decision(by: "program-manager-01", approved: true)
        let refuse = Approval.Decision(by: "program-manager-01", approved: false)

        #expect(Approval.status(decisions: [approve, refuse], pack: Self.pack) == .rejected)
        #expect(Approval.status(decisions: [refuse, approve], pack: Self.pack) == .approved)
    }

    @Test(arguments: ["amountDue", "cumulativePaid", "contractValue", "kmCompleted", "kmTotal"])
    func aNegativeAmountOrDistanceIsImpossible(field: String) {
        // Seen on the phone (#48 run 1): one extra spoken sentence and the model wrote negative numbers.
        let found = findings(facts {
            switch field {
            case "amountDue": $0.amountDue = -480_000
            case "cumulativePaid": $0.cumulativePaid = -8_500_000
            case "contractValue": $0.contractValue = -10_000_000
            case "kmCompleted": $0.kmCompleted = -32
            default: $0.kmTotal = -64
            }
        })

        #expect(found.contains(FactChecks.Finding(check: .impossibleValue, field: field)))
    }

    @Test func moreKilometresBuiltThanExistIsImpossible() {
        let found = findings(facts { $0.kmCompleted = 65 })

        #expect(found.contains(FactChecks.Finding(check: .impossibleValue, field: "kmCompleted")))
    }

    @Test func zeroAndAllOfTheRoadArePossible() {
        #expect(!checks(findings(facts { $0.kmCompleted = 0 })).contains(.impossibleValue))
        #expect(!checks(findings(facts { $0.kmCompleted = 64 })).contains(.impossibleValue))
    }

    @Test func everyFindingNamesTheFieldToReview() {
        let found = findings(facts { $0.cumulativePaid = 6_500_000 })

        #expect(FactChecks.fieldsToReview(found) == ["cumulativePaid"])
    }
}
