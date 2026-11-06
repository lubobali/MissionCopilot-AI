import Foundation
import Testing
@testable import MissionCopilot

/// The red-flag rules as data (#134, step 6.3.1; ADR 0010): each rule's id, version, source, title in
/// English and French, and its threshold, read strictly from the bundled file. A rule flags when its
/// computed value is above the threshold; an organization can tune a threshold without a new app.
struct RedFlagRulesTests {
    static func file(_ rules: String, version: Int = 1) -> Data {
        Data(#"{"version": \#(version), "rules": [\#(rules)]}"#.utf8)
    }

    static func rule(id: String = "MC-01", unit: String = "points", value: String = "20",
                     extra: String = "", title: String = "Payments ahead of physical progress") -> String {
        #"""
        {"id": "\#(id)", "version": "1", "source": "Custom", "title": {"en": "\#(title)", "fr": "Paiements"},
         "threshold": {"value": \#(value), "unit": "\#(unit)"}\#(extra)}
        """#
    }

    @Test func theBundledFileHasTheSixRulesOfADR0010InOrder() throws {
        let rules = try RedFlagRules.bundled()

        #expect(rules.rules.map(\.id) == ["R068", "R067", "MC-01", "MC-02", "MC-03", "MC-04"])
        #expect(rules.rules.allSatisfy { !$0.title.english.isEmpty && !$0.title.french.isEmpty })
    }

    @Test func theThresholdsAreTheOnesADR0010Names() throws {
        let rules = try RedFlagRules.bundled()

        #expect(rules["MC-01"]?.threshold == RedFlagRule.Threshold(value: 20, unit: .points))
        #expect(rules["R068"]?.threshold == RedFlagRule.Threshold(value: 100, unit: .percent))
        #expect(rules["R067"]?.threshold == RedFlagRule.Threshold(value: 0, unit: .days))
        #expect(rules["R068"]?.ref == RuleRef(id: "R068", version: "1"))
        #expect(rules["R068"]?.source == "Open Contracting red flags guide (2024)")
        #expect(rules["MC-99"] == nil)
        #expect(rules["MC-01"]?.title.text("fr") == "Paiements en avance sur l'avancement physique")
        #expect(rules["MC-01"]?.title.text("en") == "Payments ahead of physical progress")
    }

    @Test func aRuleFlagsOnlyAboveItsThreshold() throws {
        let threshold = RedFlagRule.Threshold(value: 20, unit: .points)

        #expect(threshold.isCrossed(by: 20.01))
        #expect(!threshold.isCrossed(by: 20))
        #expect(!threshold.isCrossed(by: 19.99))
    }

    @Test func aWellFormedFileIsRead() throws {
        let rules = try RedFlagRules(json: Self.file(Self.rule()))

        #expect(rules.rules.count == 1)
    }

    @Test(arguments: [
        ("a repeated id", file(rule() + "," + rule())),
        ("an unknown unit", file(rule(unit: "furlongs"))),
        ("an unknown field", file(rule(extra: #", "formula": "x > 1""#))),
        ("a negative threshold", file(rule(value: "-1"))),
        ("an empty title", file(rule(title: ""))),
        ("another file version", file(rule(), version: 2)),
        ("no rules", file("")),
        ("not JSON", Data("rules".utf8))
    ])
    func aBadFileIsRefused(_ why: String, _ data: Data) {
        #expect(throws: RedFlagRules.Refused.self, "\(why)") { try RedFlagRules(json: data) }
    }
}
