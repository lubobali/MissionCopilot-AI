import Foundation
import Testing
@testable import MissionCopilot

/// The bank's view of a scanned invoice (#138, step 6.5.6): what the pack already knows before the mission,
/// which a printed page can never change. Paid before the invoice is every pack payment but its own row;
/// each number cites the pack field it came from, so a later check or red flag can show its source.
struct InvoiceBankViewTests {
    static func kandor() throws -> (contracts: PackContracts, data: Data) {
        let data = try PackFiguresTests.file(PackContracts.path)
        return (try PackContracts.read(data), data)
    }

    @Test func theKandorContractHasItsPeriodAndApprover() throws {
        let contract = try #require(try Self.kandor().contracts.contracts.first)

        #expect(contract.contractPeriod == .init(start: "2025-01-15", end: "2026-12-31"))
        #expect(contract.paymentApprover == "program-manager-01")
    }

    @Test func invoice14LeavesOutItsOwnRow() throws {
        let view = try #require(try Self.kandor().contracts.bankView(invoice: "14"))

        #expect(view.paidBefore == 8_020_000)  // 8,500,000 paid in all, less invoice 14's own 480,000
        #expect(view.ownRow == 5)
        #expect(view.contractValue == 10_000_000)
        #expect(view.period == .init(start: "2025-01-15", end: "2026-12-31"))
        #expect(view.approver == "program-manager-01")
    }

    @Test func anInvoiceThePackHasNotPaidCountsEveryPayment() throws {
        let view = try #require(try Self.kandor().contracts.bankView(invoice: "15"))

        #expect(view.paidBefore == 8_500_000)
        #expect(view.ownRow == nil)
    }

    @Test func anEarlierInvoiceLeavesOutOnlyItsOwnRow() throws {
        let view = try #require(try Self.kandor().contracts.bankView(invoice: "9"))

        #expect(view.paidBefore == 6_700_000)
        #expect(view.ownRow == 2)
    }

    @Test func everyNumberCitesThePackFieldItCameFrom() throws {
        let (contracts, data) = try Self.kandor()
        let view = try #require(contracts.bankView(invoice: "14"))

        let paid = try view.sources.paidBefore.map { try $0.value(in: data) }
        let amounts: [Double] = [1_000_000, 1_500_000, 1_800_000, 2_000_000, 1_720_000]
        #expect(paid == amounts.map(JSONValue.number))
        #expect(try view.sources.contractValue.value(in: data) == .number(10_000_000))
        #expect(try view.sources.period.value(in: data)
                == .object(["start": .string("2025-01-15"), "end": .string("2026-12-31")]))
        #expect(try view.sources.approver.value(in: data) == .string("program-manager-01"))
        #expect(view.sources.paidBefore.allSatisfy { $0.sha256 == contracts.file.sha256 })
    }

    @Test func aContractThatIsNotThereHasNoView() throws {
        let contracts = try Self.kandor().contracts

        #expect(contracts.bankView(invoice: "14", contract: 1) == nil)
        #expect(contracts.bankView(invoice: "14", contract: -1) == nil)
        #expect(contracts.bankView(invoice: "14", contract: 0) != nil)
    }

    @Test func aContractWithoutItsPeriodOrApproverIsRefused() throws {
        let text = try #require(String(data: try Self.kandor().data, encoding: .utf8))

        for field in ["contractPeriod", "paymentApprover"] {
            let renamed = Data(text.replacingOccurrences(of: "\"\(field)\"", with: "\"other\"").utf8)
            #expect(throws: DecodingError.self, "\(field)") { try PackContracts.read(renamed) }
        }
    }
}
