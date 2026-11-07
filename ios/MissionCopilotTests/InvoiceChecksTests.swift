import Foundation
import Testing
@testable import MissionCopilot

/// The checks a scanned invoice's facts go through before the officer sees them (#138, step 6.5.8): grounding,
/// the code's second opinion, the page against itself (its payment table) and against the bank's own record
/// (the pack). Each problem names its field and says why in words; a fact with a problem is never confirmed
/// for the officer, only shown to them.
struct InvoiceChecksTests {
    static func bank() throws -> InvoiceBankView {
        try #require(try InvoiceBankViewTests.kandor().contracts.bankView(invoice: "14"))
    }

    static func review(_ facts: InvoiceFacts, pages: [PageReading]? = nil) throws -> FactReview {
        InvoiceChecks.review(facts, pages: try pages ?? FactGroundingTests.kandorPages(), bank: try bank())
    }

    static func facts(amountDue: Int = 480_000, cumulativePaid: Int = 8_500_000, contractValue: Int = 10_000_000,
                      invoiceDate: String = "2026-10-12", road: (built: Int, total: Int) = (32, 64)) -> InvoiceFacts {
        InvoiceFacts(invoiceNumber: "14", invoiceDate: invoiceDate, amountDue: amountDue,
                     cumulativePaid: cumulativePaid, contractValue: contractValue, kmCompleted: road.built,
                     kmTotal: road.total, bridgeStatus: "not_started")
    }

    @Test func theTrueKandorFactsPassEveryCheck() throws {
        let review = try Self.review(FactGroundingTests.truth)

        #expect(review.problems.isEmpty, "\(review.problems)")
        #expect(review.printedAt.count == 8)
        #expect(review.facts == FactGroundingTests.truth)
    }

    @Test func aFactNotPrintedIsUngrounded() throws {
        let review = try Self.review(Self.facts(road: (33, 64)))

        #expect(review.problems(for: "kmCompleted").map(\.check) == [.ungrounded, .secondOpinion])
        #expect(review.problems(for: "kmCompleted").first?.words == "Not found on the scanned pages.")
    }

    @Test func aPlantedPaidToDateFailsTheTableAndTheBank() throws {
        // Spike #8: the page prints a second "paid to date" and the model takes it. Grounding passes.
        var pages = try FactGroundingTests.kandorPages()
        pages[0] = PageReading(transcript: pages[0].transcript + "\nPaid to date, revised: USD 9,000,000",
                               tables: pages[0].tables, reader: pages[0].reader)

        let review = try Self.review(Self.facts(cumulativePaid: 9_000_000), pages: pages)

        let problems = review.problems(for: "cumulativePaid")
        #expect(problems.map(\.check) == [.secondOpinion, .rowSum, .bankRecord])
        #expect(problems.map(\.words) == [
            "The page's labels say 8,500,000 or 9,000,000; the assistant read 9,000,000.",
            "The payment table adds up to 8,500,000, not 9,000,000.",
            "The bank paid 8,020,000 before this invoice; with this invoice's 480,000 that is 8,500,000, "
                + "not 9,000,000."
        ])
    }

    @Test func aContractValueOtherThanTheBanksIsAProblem() throws {
        let review = try Self.review(Self.facts(contractValue: 12_000_000),
                                     pages: [FactGroundingTests.page("Contract value: USD 12,000,000")])

        #expect(review.problems(for: "contractValue").map(\.words)
                == ["The bank's contract value is 10,000,000, not 12,000,000."])
    }

    @Test func anAmountOverWhatIsLeftOnTheContractIsAProblem() throws {
        let review = try Self.review(Self.facts(amountDue: 2_000_000))

        #expect(review.problems(for: "amountDue").map(\.check)
                == [.secondOpinion, .invoiceRow, .contractRemaining])
        #expect(review.problems(for: "amountDue").last?.words
                == "Only 1,980,000 is left on the contract, less than 2,000,000.")
    }

    @Test func anInvoiceDateOutsideTheContractIsAProblem() throws {
        let review = try Self.review(Self.facts(invoiceDate: "2027-01-05"))

        #expect(review.problems(for: "invoiceDate").map(\.check) == [.ungrounded, .secondOpinion, .contractPeriod])
        #expect(review.problems(for: "invoiceDate").last?.words
                == "Outside the contract period, 2025-01-15 to 2026-12-31.")
        #expect(InvoiceChecks.isInside("2026-02-30", from: "2025-01-15", to: "2026-12-31") == false)
        #expect(InvoiceChecks.isInside("2025-01-15", from: "2025-01-15", to: "2026-12-31"))
        #expect(InvoiceChecks.isInside("2026-12-31", from: "2025-01-15", to: "2026-12-31"))
    }

    @Test func impossibleValuesAreProblems() throws {
        let review = try Self.review(Self.facts(road: (70, 64)))

        #expect(review.problems(for: "kmCompleted").last?.words == "More road built than the road's length.")
        let negative = try Self.review(Self.facts(amountDue: -480_000))
        #expect(negative.problems(for: "amountDue").contains { $0.words == "Cannot be below zero." })
    }

    @Test func theInvoicesOwnRowMustMatchItsAmount() throws {
        var pages = try FactGroundingTests.kandorPages()
        pages[0] = PageReading(transcript: pages[0].transcript,
                               tables: [pages[0].tables[0].filter { $0[1] != "Invoice 14" }], reader: pages[0].reader)

        let review = try Self.review(FactGroundingTests.truth, pages: pages)

        #expect(review.problems(for: "amountDue").map(\.words) == ["Invoice 14 is not in the payment table."])
    }

    @Test func noPaymentTableOrAnUnreadableRowIsSaid() throws {
        let none = try Self.review(FactGroundingTests.truth, pages: [FactGroundingTests.page("Invoice No. 14")])
        #expect(none.problems(for: "cumulativePaid").contains {
            $0.words == "No payment table was read, so it could not be added up."
        })

        var pages = try FactGroundingTests.kandorPages()
        var table = pages[0].tables[0]
        table[2][2] = "1,5OO,000"  // an OCR "O" for "0" is not a number
        pages[0] = PageReading(transcript: pages[0].transcript, tables: [table], reader: pages[0].reader)
        let unreadable = try Self.review(FactGroundingTests.truth, pages: pages)
        #expect(unreadable.problems(for: "cumulativePaid").map(\.words)
                == ["Row 2 of the payment table cannot be read as a number."])
    }

    @Test func withoutTheBanksRecordThePackChecksSaySo() throws {
        let review = InvoiceChecks.review(FactGroundingTests.truth, pages: try FactGroundingTests.kandorPages(),
                                          bank: nil)

        #expect(review.problems.map(\.field) == ["contractValue"])
        #expect(review.problems.first?.words == "The mission pack has no contract to check it against.")
    }

    @Test func everyFieldHasAName() {
        #expect(InvoiceFacts.fields.map(InvoiceFacts.name) == [
            "Invoice number", "Invoice date", "Amount due", "Paid to date", "Contract value", "Road built",
            "Road length", "Section 3 bridge"
        ])
    }
}
