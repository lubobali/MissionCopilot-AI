import Foundation
import Testing
@testable import MissionCopilot

/// A short report (#161, step 7.2.7, found on the iPhone: 77 sentences): a scanned invoice is one sentence, the
/// same sentence twice is one citing both, and only the overall rating, for any mission.
struct ShortReportTests {
    /// One scanned invoice: its 8 facts as the app stores them, `typed` ones the officer typed (not on the page).
    static func scan(_ tag: String, number: String, kmBuilt: String = "32", typed: Set<String> = []) -> [Fact] {
        let values = ["invoiceNumber": number, "invoiceDate": "2026-10-12", "amountDue": "480000",
                      "cumulativePaid": "8500000", "contractValue": "10000000", "kmCompleted": kmBuilt,
                      "kmTotal": "64", "bridgeStatus": "not_started"]
        let units = ["amountDue": "USD", "cumulativePaid": "USD", "contractValue": "USD", "kmCompleted": "km",
                     "kmTotal": "km"]
        return InvoiceFacts.fields.enumerated().map { index, field in
            Fact(id: "\(tag)-\(field)", name: field, value: values[field] ?? "", unit: units[field],
                 rule: typed.contains(field) ? MissionStore.officerRule : MissionStore.scanRule,
                 classification: .officialUseOnly,
                 sources: [FactSource(seq: 10 + index, region: typed.contains(field) ? nil : "r\(index)")])
        }
    }

    static func note(_ id: String, _ kind: String, _ text: String) -> Fact {
        Fact(id: id, name: "debrief.\(kind)", value: #"{"byWhen":"","text":"\#(text)","who":""}"#, unit: nil,
             rule: MissionStore.debriefRule, classification: .officialUseOnly,
             sources: [FactSource(seq: 3, region: id)])
    }

    /// The report of these facts and pack files; each pack record gets its report fact, as `reportFacts` writes.
    static func written(_ facts: [Fact], packFiles: [String: Data] = [:]) -> [ReportLine] {
        let sources = MissionSources.build(SourceInputs(packFiles: packFiles, facts: facts))
        let records = sources.filter { $0.kind == .pack }.map { source in
            Fact(id: "pack-\(source.id)", name: source.id, value: "", unit: nil, rule: ReportRules.packRecord,
                 classification: .officialUseOnly, sources: [FactSource(seq: 1, region: source.id)])
        }
        return ReportWriter.write(sources: sources, facts: facts + records, flagged: [], language: .english)
    }

    /// A scanned invoice is one sentence citing its 8 facts, not 8 sentences; a typed value says so.
    @Test func aScannedInvoiceIsOneSentence() {
        let facts = Self.scan("a", number: "14") + Self.scan("b", number: "15", kmBuilt: "40", typed: ["kmCompleted"])

        let lines = Self.written(facts)

        #expect(lines.count == 2, "\(lines.map(\.text))")
        #expect(lines.first?.text == "From your scanned invoice: Invoice number: 14; Invoice date: 12 October 2026; "
                + "Amount due: USD 480,000; Paid to date: USD 8,500,000; Contract value: USD 10,000,000; "
                + "Road built: 32 km; Road length: 64 km; Section 3 bridge: Not started.")
        #expect(lines.first?.factIds == Self.scan("a", number: "14").map(\.id))
        #expect(lines.last?.text.contains("Road built: 40 km (typed by you, not on the page);") == true,
                "\(lines.last?.text ?? "")")
        #expect(lines.allSatisfy { $0.section == .findings && $0.checked && $0.factIds.count == 8 })
    }

    /// The same sentence twice (a note said in two debriefs, an invoice scanned twice) is one, citing both.
    @Test func theSameSentenceTwiceIsOneCitingBoth() {
        let facts = [Self.note("n1", "risk", "Risk, the rains may delay the works."),
                     Self.note("n2", "risk", "Risk, the rains may delay the works.")]
            + Self.scan("a", number: "14") + Self.scan("b", number: "14")

        let lines = Self.written(facts)

        #expect(lines.count == 2, "\(lines.map(\.text))")
        #expect(lines.first { $0.text.hasPrefix("From your debrief") }?.factIds == ["n1", "n2"])
        #expect(lines.first { $0.text.hasPrefix("From your scanned") }?.factIds.count == 16)
        #expect(Set(lines.map(\.id)).count == lines.count, "each sentence once")
    }

    /// Universal (Lubo: "is it universal for any mission"): a made-up water mission in another country, its own
    /// pack, three scans (one twice) and repeated notes, comes out short, each sentence once and proven.
    @Test func anotherMissionIsShortToo() throws {
        let contracts = #"""
            {"contracts":[{"title":"Zarnia town water mains","contractValue":4200000,"status":"active",\#
            "supplier":"Zarnia Pipeworks","physicalProgress":{"asOf":"2026-08-31","kmBuilt":11,"kmTotal":40,\#
            "unit":"km of pipe"}}],"currency":"USD"}
            """#
        let rating = { (now: String, before: String) in #"{"current":"\#(now)","previous":"\#(before)"}"# }
        let ratings = #"{"asOf":"2026-08-31","pdoProgress":\#(rating("Satisfactory", "Satisfactory")),"#
            + #""implementationProgress":\#(rating("Moderately Satisfactory", "Satisfactory")),"#
            + #""financialManagement":\#(rating("Satisfactory", "Satisfactory")),"#
            + #""procurement":\#(rating("Satisfactory", "Moderately Satisfactory")),"#
            + #""environmentalSocial":\#(rating("Satisfactory", "Satisfactory")),"#
            + #""overallRisk":\#(rating("Moderate", "Moderate"))}"#
        let files = ["sections/contracts.json": Data(contracts.utf8), "sections/ratings.json": Data(ratings.utf8)]
        let facts = Self.scan("a", number: "3") + Self.scan("b", number: "4") + Self.scan("c", number: "4")
            + (1...6).map { Self.note("d\($0)", "decision", "Decision, the town fixes the pump station first.") }
            + (1...3).map { Self.note("x\($0)", "action", "Action, the supplier sends the test results.") }

        let lines = Self.written(facts, packFiles: files)
        let texts = lines.map(\.text)

        #expect(lines.count <= 8, "\(texts)")
        #expect(texts.contains("Physical progress: 11 of 40 km of pipe built, as of 31 Aug 2026."), "\(texts)")
        #expect(texts.contains("Overall risk: Moderate (Moderate before)."), "\(texts)")
        #expect(!texts.contains { $0.contains("Satisfactory") }, "only the overall rating")
        #expect(texts.filter { $0.hasPrefix("From your scanned invoice") }.count == 2)
        #expect(Set(lines.map(\.id)).count == lines.count)
        #expect(lines.allSatisfy { $0.checked && !$0.factIds.isEmpty }, "\(lines.filter { !$0.checked })")
    }

    /// The invoice's sentence is checked against every record it cites: a number its records do not hold (here a
    /// record that says USD 5) leaves it with no proof, never quietly in the report.
    @Test func anInvoiceSentenceIsCheckedAgainstItsRecords() {
        let facts = Self.scan("a", number: "14")
        let sources = facts.map { fact in
            let source = MissionSources.fact(fact)
            guard fact.name == "amountDue" else { return source }
            return MissionSource(id: source.id, kind: source.kind, title: source.title, text: "Amount due: 5 USD",
                                 origin: source.origin)
        }

        let lines = ReportWriter.write(sources: sources, facts: facts, flagged: [], language: .english)

        #expect(lines.count == 1)
        #expect(lines.first?.checked == false)
        #expect(lines.first?.reason?.hasPrefix("The number") == true, "\(lines.first?.reason ?? "")")
    }
}
