import Foundation
import Testing
@testable import MissionCopilot

/// The red-flag engine (#134, step 6.3.3; ADR 0010): pure code, inputs in, one or more results per rule
/// out. Each result is a flag, clear, or not checked with its reason (a missing input is never clear), and
/// carries the computed value, the threshold and the citations of every input it used.
struct RedFlagEngineTests {
    static let rules = (try? RedFlagRules.bundled()) ?? RedFlagRules.empty
    static let walkDay = SiteWalkTests.walkDay  // 2026-11-10

    static func contracts(value: Int = 10_000, payments: [Int] = [6_000], built: Double = 32, total: Double = 64,
                          references: [String]? = nil) throws -> PackContracts {
        let refs = references ?? payments.indices.map { "Invoice \($0 + 1)" }
        let items = zip(payments, refs).map { #"{"amount": \#($0), "date": "2026-01-01", "reference": "\#($1)"}"# }
        let json = #"""
            {"currency": "USD", "contracts": [{"ocid": "ocds-x", "title": "Road", "method": "RFB",
             "status": "active", "supplier": "S", "contractValue": \#(value), "paymentApprover": "p",
             "contractPeriod": {"start": "2025-01-01", "end": "2026-12-31"},
             "payments": [\#(items.joined(separator: ","))],
             "physicalProgress": {"asOf": "2026-09-30", "kmBuilt": \#(built), "kmTotal": \#(total), "unit": "km"}}]}
            """#
        return try PackContracts.read(Data(json.utf8))
    }

    struct Row {
        let due: String
        let met: String?
        let status: String
        init(_ due: String, _ met: String?, _ status: String) {
            self.due = due
            self.met = met
            self.status = status
        }
    }

    static func milestones(_ items: [Row]) throws -> PackMilestones {
        let rows = items.enumerated().map { index, item in
            let met = item.met.map { "\"\($0)\"" } ?? "null"
            return #"{"id": "M\#(index + 1)", "title": "T", "dueDate": "\#(item.due)", "dateMet": \#(met), "#
                + #""status": "\#(item.status)"}"#
        }
        let json = #"{"asOf": "2026-11-10", "locations": [], "milestones": [\#(rows.joined(separator: ","))]}"#
        return try PackMilestones.read(Data(json.utf8))
    }

    static func run(contracts: PackContracts? = nil, milestones: PackMilestones? = nil) -> [RedFlagResult] {
        RedFlagEngine(rules: rules).run(RedFlagInputs(contracts: contracts, milestones: milestones),
                                        walk: walkDay, timeZone: .gmt)
    }

    static func only(_ rule: String, _ results: [RedFlagResult]) -> [RedFlagResult] {
        results.filter { $0.rule.id == rule }
    }

    // MARK: Kandor

    @Test func theKandorPackGivesTwoFlagsTwoClearAndTwoNotChecked() throws {
        let contracts = try PackContracts.read(try PackFiguresTests.file(PackContracts.path))
        let milestones = try PackMilestones.read(try PackFiguresTests.file(PackMilestones.path))

        let results = Self.run(contracts: contracts, milestones: milestones)

        #expect(results.map(\.rule.id) == ["R068", "R067", "MC-01", "MC-02", "MC-03", "MC-04"])
        let expected: [RedFlagResult.Outcome] = [.clear, .flag, .flag, .clear, .notChecked(.needsScan),
                                                 .notChecked(.needsPhotos)]
        #expect(results.map(\.outcome) == expected)
        #expect(results[0].computed == 85)
        #expect(results[1].subject == "M3")
        #expect(results[1].computed == 41, "Sep 30 to Nov 10")
        #expect(results[2].computed == 35, "85% paid, 50% built")
    }

    @Test func aFlagCitesEveryPackFieldItUsedAndEachReadsBack() throws {
        let data = try PackFiguresTests.file(PackContracts.path)
        let result = try #require(Self.only("MC-01", Self.run(contracts: try PackContracts.read(data))).first)

        let pointers = result.inputs.compactMap { input -> String? in
            if case .pack(let citation) = input { return citation.pointer }
            return nil
        }
        #expect(pointers == ["/contracts/0/contractValue"] + (0..<6).map { "/contracts/0/payments/\($0)/amount" }
                + ["/contracts/0/physicalProgress/kmBuilt", "/contracts/0/physicalProgress/kmTotal"])
        for case .pack(let citation) in result.inputs { _ = try citation.value(in: data) }
        #expect(result.threshold == RedFlagRule.Threshold(value: 20, unit: .points))
    }

    // MARK: R068 paid more than the contract value (percent of the value, above 100)

    @Test(arguments: [(9_999, RedFlagResult.Outcome.clear), (10_000, .clear), (10_001, .flag)])
    func paidAgainstTheContractValue(paid: Int, outcome: RedFlagResult.Outcome) throws {
        let result = Self.only("R068", Self.run(contracts: try Self.contracts(payments: [paid])))

        #expect(result.map(\.outcome) == [outcome])
    }

    @Test func aZeroContractValueIsNotCheckedNeverClear() throws {
        let results = Self.run(contracts: try Self.contracts(value: 0, payments: [10]))

        #expect(Self.only("R068", results).map(\.outcome) == [.notChecked(.zeroValue)])
        #expect(Self.only("MC-01", results).map(\.outcome) == [.notChecked(.zeroValue)])
    }

    @Test func withNoContractsThePaymentRulesAreNotChecked() {
        let results = Self.run()

        for rule in ["R068", "MC-01", "MC-02"] {
            #expect(Self.only(rule, results).map(\.outcome) == [.notChecked(.noContracts)], "\(rule)")
        }
        #expect(Self.only("R067", results).map(\.outcome) == [.notChecked(.noMilestones)])
    }

    // MARK: R067 a milestone late and not met (days late, above 0)

    @Test func aMilestoneDueOnTheWalkDayIsNotLateYet() throws {
        let results = Self.only("R067", Self.run(milestones: try Self.milestones([Row("2026-11-10", nil, "notMet")])))

        #expect(results.map(\.outcome) == [.clear])
    }

    @Test func aMilestoneOneDayPastDueAndNotMetIsFlagged() throws {
        let results = Self.only("R067", Self.run(milestones: try Self.milestones([Row("2026-11-09", nil, "notMet")])))

        #expect(results.map(\.outcome) == [.flag])
        #expect(results.first?.computed == 1)
        #expect(results.first?.subject == "M1")
    }

    @Test func eachLateMilestoneIsItsOwnFlagAndMetOnesAreNot() throws {
        let milestones = try Self.milestones([Row("2026-01-01", "2026-03-01", "met"),
                                              Row("2026-02-01", nil, "partiallyMet"),
                                              Row("2026-03-01", nil, "scheduled"), Row("2027-01-01", nil, "scheduled")])

        let results = Self.only("R067", Self.run(milestones: milestones))

        #expect(results.map(\.subject) == ["M2", "M3"])
        #expect(results.allSatisfy { (result: RedFlagResult) -> Bool in result.outcome == .flag })
    }

    @Test func theDaysLateCountInTheOfficersOwnTimeZone() throws {
        // 01:00 on Nov 10 in Kandor's zone is still Nov 9 in Chicago.
        let walk = try #require(ISO8601DateFormatter().date(from: "2026-11-10T01:00:00Z"))
        let milestones = try Self.milestones([Row("2026-11-09", nil, "notMet")])

        let zone = try #require(TimeZone(identifier: "America/Chicago"))
        let chicago = RedFlagEngine(rules: Self.rules).run(RedFlagInputs(milestones: milestones), walk: walk,
                                                           timeZone: zone)

        #expect(Self.only("R067", chicago).map(\.outcome) == [.clear])
    }

    // MARK: MC-01 payments ahead of physical progress (points, above 20)

    @Test(arguments: [(6_999, RedFlagResult.Outcome.clear), (7_000, .clear), (7_001, .flag)])
    func paidAheadOfBuilt(paid: Int, outcome: RedFlagResult.Outcome) throws {
        // 32 of 64 km is 50%; 70% paid is exactly 20 points ahead.
        let result = Self.only("MC-01", Self.run(contracts: try Self.contracts(payments: [paid])))

        #expect(result.map(\.outcome) == [outcome])
    }

    @Test func buildingAheadOfPaymentIsNotAFlag() throws {
        let result = Self.only("MC-01", Self.run(contracts: try Self.contracts(payments: [1_000], built: 64)))

        #expect(result.map(\.outcome) == [.clear])
        #expect(result.first?.computed == -90)
    }

    // MARK: MC-02 the same invoice twice (count, above 1)

    @Test func theSameReferenceTwiceIsAFlagNamingIt() throws {
        let contracts = try Self.contracts(payments: [100, 200, 300],
                                           references: ["Invoice 6", "Invoice 7", "Invoice 6"])

        let result = Self.only("MC-02", Self.run(contracts: contracts))

        #expect(result.map(\.outcome) == [.flag])
        #expect(result.first?.subject == "Invoice 6")
        #expect(result.first?.computed == 2)
    }

    @Test func theSameAmountTwiceIsAFlagNamingIt() throws {
        let result = Self.only("MC-02", Self.run(contracts: try Self.contracts(payments: [500, 700, 500])))

        #expect(result.map(\.outcome) == [.flag])
        #expect(result.first?.subject == "500")
    }

    @Test func differentInvoicesAreClear() throws {
        let result = Self.only("MC-02", Self.run(contracts: try Self.contracts(payments: [100, 200, 300])))

        #expect(result.map(\.outcome) == [.clear])
        #expect(result.first?.computed == 1)
    }

    // MARK: a rule the app has no code for

    @Test func aRuleThisAppCannotComputeIsNotCheckedNeverDropped() throws {
        let file = RedFlagRulesTests.file(RedFlagRulesTests.rule(id: "MC-99"))
        let engine = RedFlagEngine(rules: try RedFlagRules(json: file))

        let results = engine.run(RedFlagInputs(), walk: Self.walkDay, timeZone: .gmt)

        #expect(results.map(\.outcome) == [.notChecked(.unknownRule)])
        #expect(results.map(\.rule.id) == ["MC-99"])
    }
}
