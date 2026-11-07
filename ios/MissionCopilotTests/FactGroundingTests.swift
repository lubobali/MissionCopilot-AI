import Foundation
import Testing
@testable import MissionCopilot

/// Grounding and the second opinion (#138, step 6.5.8): each fact the model filled must be printed on a
/// scanned page, and the app keeps where (page and position in that page's text) as its source. Code also
/// reads the fixed labels itself ("Amount due ...: USD 480,000"); a value the model picked elsewhere on the
/// page is a problem even when it is printed there (spike #8's planted values).
struct FactGroundingTests {
    static let key = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "docs/demo/scans/answer-key.json")

    /// The Kandor pages as Vision reads them: each page's lines, then its table (headers and rows).
    static func kandorPages() throws -> [PageReading] {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: key)) as? [String: Any])
        let pages = try #require(json["pages"] as? [String: [String: Any]])
        let tables = try #require(json["tables"] as? [String: [String: Any]])
        return try ["invoice-14", "progress-report-2026-09"].map { name in
            let lines = try #require(pages[name]?["lines"] as? [String])
            let headers = try #require(tables[name]?["headers"] as? [String])
            let rows = try #require(tables[name]?["rows"] as? [[String]])
            return PageReading(transcript: lines.joined(separator: "\n"), tables: [[headers] + rows],
                               reader: PageReading.currentReader)
        }
    }

    static let truth = InvoiceFacts(invoiceNumber: "14", invoiceDate: "2026-10-12", amountDue: 480_000,
                                    cumulativePaid: 8_500_000, contractValue: 10_000_000, kmCompleted: 32,
                                    kmTotal: 64, bridgeStatus: "not_started")

    static func facts(amountDue: Int = 480_000, cumulativePaid: Int = 8_500_000, contractValue: Int = 10_000_000,
                      invoiceDate: String = "2026-10-12", bridge: String = "not_started") -> InvoiceFacts {
        InvoiceFacts(invoiceNumber: "14", invoiceDate: invoiceDate, amountDue: amountDue,
                     cumulativePaid: cumulativePaid, contractValue: contractValue, kmCompleted: 32, kmTotal: 64,
                     bridgeStatus: bridge)
    }

    static func page(_ text: String, table: [[String]] = []) -> PageReading {
        PageReading(transcript: text, tables: table.isEmpty ? [] : [table], reader: PageReading.currentReader)
    }

    @Test func everyKandorFactIsFoundWithItsPageAndPosition() throws {
        let pages = try Self.kandorPages()

        let found = FactGrounding.sources(Self.truth, in: pages)

        #expect(Set(found.keys) == Set(InvoiceFacts.fields))
        #expect(found["amountDue"] == PrintedAt(page: 0, offset: try Self.offset("USD 480,000", page: 0) + 4,
                                                 text: "480,000"))
        #expect(found["kmCompleted"]?.page == 1)
        #expect(found["bridgeStatus"]?.text == "bridge: not started")
        for (field, source) in found {
            let text = FactGrounding.text(pages[source.page])
            let start = text.index(text.startIndex, offsetBy: source.offset)
            #expect(text[start...].hasPrefix(source.text), "\(field)")
        }
    }

    private static func offset(_ needle: String, page: Int) throws -> Int {
        let text = FactGrounding.text(try kandorPages()[page])
        let range = try #require(text.range(of: needle))
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    @Test func thePageTextIsItsLinesThenItsTableOnOneLineOfSpaces() {
        let page = Self.page("Date: 12\nOctober   2026", table: [["Ref", "Amount"], ["Invoice 14", "480,000"]])

        #expect(FactGrounding.text(page) == "Date: 12 October 2026 Ref | Amount Invoice 14 | 480,000")
    }

    @Test func aDateBrokenOverTwoLinesIsStillFound() {
        let found = FactGrounding.sources(Self.truth, in: [Self.page("Date: 12\nOctober 2026")])

        #expect(found["invoiceDate"]?.text == "12 October 2026")
    }

    @Test func aNumberInsideABiggerNumberIsNotFound() {
        let pages = [Self.page("Invoice No. 14\nAmount due: USD 1,480,000")]

        #expect(FactGrounding.sources(Self.facts(amountDue: 480_000), in: pages)["amountDue"] == nil)
        #expect(FactGrounding.sources(Self.facts(amountDue: 1_480_000), in: pages)["amountDue"] != nil)
    }

    @Test func invoiceOneIsNotFoundInsideInvoiceFourteen() {
        let one = InvoiceFacts(invoiceNumber: "1", invoiceDate: "2026-10-12", amountDue: 1, cumulativePaid: 1,
                               contractValue: 1, kmCompleted: 1, kmTotal: 1, bridgeStatus: "not_started")

        #expect(FactGrounding.sources(one, in: [Self.page("Invoice No. 14")])["invoiceNumber"] == nil)
    }

    @Test func aMilestoneRowIsNotTheBridgeStatusLine() throws {
        let found = FactGrounding.sources(Self.facts(bridge: "completed"), in: try Self.kandorPages())

        #expect(found["bridgeStatus"] == nil)  // the table says "Section 3 bridge complete", the line "not started"
    }

    @Test func onKandorTheCodeReadsWhatTheModelRead() throws {
        #expect(FactGrounding.secondOpinion(Self.truth, in: try Self.kandorPages()).isEmpty)
    }

    @Test func aValuePrintedElsewhereButNotUnderItsLabelIsAProblem() throws {
        // 1,720,000 is printed (invoice 13's row), so grounding passes; the "Amount due" label says 480,000.
        let pages = try Self.kandorPages()
        let picked = Self.facts(amountDue: 1_720_000)

        #expect(FactGrounding.sources(picked, in: pages)["amountDue"] != nil)
        #expect(FactGrounding.secondOpinion(picked, in: pages) == ["amountDue": "480,000"])
    }

    @Test func theCodeReadsEachFixedLabel() throws {
        let read = FactGrounding.labelled(in: try Self.kandorPages())

        #expect(read["amountDue"] == ["480,000"])
        #expect(read["cumulativePaid"] == ["8,500,000"])
        #expect(read["contractValue"] == ["10,000,000"])
        #expect(read["invoiceDate"] == ["12 October 2026"])
        #expect(read["kmCompleted"] == ["32"])
        #expect(read["kmTotal"] == ["64"])
    }

    @Test func aLabelPrintedTwiceWithTwoValuesIsReadBothTimes() {
        let pages = [Self.page("Amount due this invoice: USD 480,000\nTotal amount due: USD 4,800,000")]

        #expect(FactGrounding.labelled(in: pages)["amountDue"] == ["480,000", "4,800,000"])
        #expect(FactGrounding.secondOpinion(Self.truth, in: pages)["amountDue"] == "480,000 or 4,800,000")
    }
}
