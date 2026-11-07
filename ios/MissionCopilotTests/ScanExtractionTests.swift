import Foundation
import Testing
@testable import MissionCopilot

/// Scanned pages to facts (#138, step 6.5.7): the pages' text and tables go through the one model door
/// (FieldModel) with spike #13's invoice schema, 8 facts. Only a schema-valid answer within the time limit
/// becomes facts to check; too long, stopped, refused or no model goes to the officer, never into facts.
struct ScanExtractionTests {
    typealias FakeEngine = FieldModelTests.FakeEngine

    static let invoice = PageReading(transcript: "Invoice No. 14\nAmount due this invoice: USD 480,000",
                                     tables: [[["Date", "Reference", "Amount (USD)"],
                                               ["12 Oct 2026", "Invoice 14", "480,000"]]],
                                     reader: PageReading.currentReader)
    static let report = PageReading(transcript: "Road built: 32 of 64 km of asphalt", tables: [],
                                    reader: PageReading.currentReader)
    static let answer = #"""
        {"invoiceNumber":"14","invoiceDate":"2026-10-12","amountDue":480000,"cumulativePaid":8500000,
         "contractValue":10000000,"kmCompleted":32,"kmTotal":64,"bridgeStatus":"not_started"}
        """#

    @Test func theSourceIsEachPageTextThenItsTablesOneRowPerLine() {
        #expect(ScanExtraction.source([Self.invoice, Self.report]) == """
            Invoice No. 14
            Amount due this invoice: USD 480,000
            Date | Reference | Amount (USD)
            12 Oct 2026 | Invoice 14 | 480,000

            Road built: 32 of 64 km of asphalt
            """)
    }

    @Test func theTaskAsksForTheEightFactsWithTheInvoiceSchema() throws {
        let task = ScanExtraction.task("SOURCE TEXT")

        #expect(task.prompt.hasSuffix("\n\nSOURCE TEXT"))
        #expect(task.prompt.contains("Amounts are whole US dollars without commas"))
        #expect(task.schema == InvoiceFacts.schema)
        #expect(task.maxTokens == 256)
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(task.schema.utf8)) as? [String: Any])
        #expect(schema["required"] as? [String] == InvoiceFacts.fields)
        #expect(InvoiceFacts.fields.count == 8)
        #expect(schema["additionalProperties"] as? Bool == false)
    }

    @Test func aValidAnswerBecomesFactsToCheck() async throws {
        let engine = FakeEngine(answer: Self.answer)

        let outcome = await ScanExtraction.extract([Self.invoice, Self.report], model: FieldModel(engine: engine))

        #expect(outcome == .read(InvoiceFacts(invoiceNumber: "14", invoiceDate: "2026-10-12", amountDue: 480_000,
                                              cumulativePaid: 8_500_000, contractValue: 10_000_000,
                                              kmCompleted: 32, kmTotal: 64, bridgeStatus: "not_started")))
        let asked = await engine.asked
        #expect(asked.count == 1)
        #expect(asked.first?.prompt.contains("Road built: 32 of 64 km of asphalt") == true)
        #expect(asked.first?.schema == InvoiceFacts.schema)
    }

    @Test func tooMuchTextGoesToTheOfficerAndNeverReachesTheModel() async {
        let engine = FakeEngine(answer: Self.answer)
        let huge = PageReading(transcript: String(repeating: "x", count: FieldModel.maxInputCharacters),
                               tables: [], reader: PageReading.currentReader)

        let outcome = await ScanExtraction.extract([huge], model: FieldModel(engine: engine))

        guard case .toOfficer(.tooLong(let characters)) = outcome else {
            Issue.record("expected too long, got \(outcome)")
            return
        }
        #expect(characters > FieldModel.maxInputCharacters)
        #expect(await engine.asked.isEmpty)
    }

    @Test func noTextGoesToTheOfficerAndNeverReachesTheModel() async {
        let engine = FakeEngine(answer: Self.answer)
        let blank = PageReading(transcript: " \n ", tables: [], reader: PageReading.currentReader)

        #expect(await ScanExtraction.extract([], model: FieldModel(engine: engine)) == .toOfficer(.noText))
        #expect(await ScanExtraction.extract([blank], model: FieldModel(engine: engine)) == .toOfficer(.noText))
        #expect(await engine.asked.isEmpty)
    }

    @Test func aStoppedAnswerGoesToTheOfficer() async {
        let engine = FakeEngine(answer: Self.answer, delay: .seconds(5))
        let model = FieldModel(engine: engine, limit: TimeLimit(.milliseconds(100)))

        #expect(await ScanExtraction.extract([Self.invoice], model: model) == .toOfficer(.stopped))
    }

    @Test func anAnswerOutsideTheSchemaGoesToTheOfficer() async {
        let missingField = #"{"invoiceNumber":"14","amountDue":480000}"#

        for raw in [missingField, "Paid to date is 8,500,000.", ""] {
            let model = FieldModel(engine: FakeEngine(answer: raw))
            let outcome = await ScanExtraction.extract([Self.invoice], model: model)
            #expect(outcome == .toOfficer(.notUsable), "\(raw)")
        }
    }

    @Test func noModelGoesToTheOfficerSayingWhy() async {
        struct Missing: ModelEngine {
            func generate(_ request: ModelRequest) async throws -> String { throw ModelUnavailable.notInThisBuild }
        }

        #expect(await ScanExtraction.extract([Self.invoice], model: FieldModel(engine: Missing()))
                == .toOfficer(.unavailable(.notInThisBuild)))
    }

    @Test func everyReasonSaysWhatToDoInWords() {
        let reasons: [ScanExtraction.Why] = [.noText, .tooLong(characters: 25_000), .stopped, .notUsable,
                                             .unavailable(.notInThisBuild), .unavailable(.failedCheck),
                                             .unavailable(.couldNotLoad)]
        let words = reasons.map(\.words)

        #expect(Set(words).count == reasons.count)
        #expect(words.allSatisfy { $0.hasSuffix(".") && !$0.isEmpty })
        #expect(ScanExtraction.Why.tooLong(characters: 25_000).words.contains("25,000"))
    }

    @Test func theSelfTestAsksForTheSameEightFacts() {
        #expect(ModelSelfTest.task.schema == InvoiceFacts.schema)
    }
}
