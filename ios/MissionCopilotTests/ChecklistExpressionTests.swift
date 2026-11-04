import Foundation
import Testing
@testable import MissionCopilot

/// The checklist's expressions read by a small parser of our own (#93, threat T54): the ODK subset a
/// checklist uses, with XPath's order of operations, never run as code. What it cannot read is marked
/// "cannot read" and never blocks the form; only a regex() pattern that could hang the phone refuses it.
struct ChecklistExpressionTests {
    typealias Node = ChecklistExpression.Node

    static func read(_ text: String) throws -> Node? {
        if case .read(let node) = try ChecklistExpression.read(text) { node } else { nil }
    }

    static func number(_ value: Double) -> Node { .number(value) }
    static func ref(_ name: String) -> Node { .reference(name) }

    // Order of operations, as in XPath

    @Test func theKandorWidthConstraintReads() throws {
        #expect(try Self.read(". > 0 and . < 20") == .binary(.both, .binary(.greater, .current, Self.number(0)),
                                                              .binary(.less, .current, Self.number(20))))
    }

    @Test func timesBeforePlusAndAndBeforeOr() throws {
        #expect(try Self.read("1 + 2 * 3") == .binary(.plus, Self.number(1),
                                                      .binary(.times, Self.number(2), Self.number(3))))
        #expect(try Self.read("${a} = 'x' or ${b} > 2 and ${c} != 3") == .binary(
            .either, .binary(.equal, Self.ref("a"), .string("x")),
            .binary(.both, .binary(.greater, Self.ref("b"), Self.number(2)),
                    .binary(.notEqual, Self.ref("c"), Self.number(3)))))
    }

    @Test func comparisonsBindTighterThanEquality() throws {
        #expect(try Self.read("${a} < 2 = ${b} >= 3") == .binary(
            .equal, .binary(.less, Self.ref("a"), Self.number(2)),
            .binary(.greaterOrEqual, Self.ref("b"), Self.number(3))))
    }

    @Test func operatorsOfOneLevelGoLeftToRight() throws {
        #expect(try Self.read("10 - 4 - 3") == .binary(.minus, .binary(.minus, Self.number(10), Self.number(4)),
                                                       Self.number(3)))
        #expect(try Self.read("8 div 4 mod 3") == .binary(.modulo, .binary(.divide, Self.number(8), Self.number(4)),
                                                          Self.number(3)))
    }

    @Test func minusInFrontAndParenthesesAndBothQuotes() throws {
        #expect(try Self.read("-${a} <= -1.5") == .binary(.lessOrEqual, .negative(Self.ref("a")),
                                                          .negative(Self.number(1.5))))
        #expect(try Self.read("(1 + 2) * 3") == .binary(.times, .binary(.plus, Self.number(1), Self.number(2)),
                                                        Self.number(3)))
        #expect(try Self.read(#"${a} = "x y""#) == .binary(.equal, Self.ref("a"), .string("x y")))
        #expect(try Self.read(".5 < .") == .binary(.less, Self.number(0.5), .current))
    }

    // The functions

    @Test(arguments: [
        ("selected(${q}, 'a')", ChecklistExpression.Function.selected, 2),
        ("count-selected(${q})", .countSelected, 1), ("string-length(.)", .stringLength, 1),
        ("string-length()", .stringLength, 0), ("if(${a} = 'yes', 1, 0)", .choose, 3),
        ("coalesce(${x}, 0)", .coalesce, 2), ("number('3')", .number, 1), ("int(2.7)", .int, 1),
        ("today()", .today, 0), ("not(${a} = 'yes')", .not, 1), ("regex(., '^[0-9]{3}$')", .regex, 2)
    ])
    func eachFunctionReadsWithItsArguments(text: String, function: ChecklistExpression.Function, count: Int)
        throws {
        guard case .call(let called, let arguments)? = try Self.read(text) else {
            Issue.record("not a call: \(text)")
            return
        }
        #expect(called == function && arguments.count == count)
    }

    // What it cannot read: marked, never a crash and never a refusal

    @Test(arguments: [
        "jr:choice-name(${a}, '${a}')", "now()", "/data/a = 1", "${a} +", "1 +* 2", "'not closed", "${}",
        "width", "selected(${a})", "if(1, 2)", "today(1)", "string-length(1, 2)", "${a} = 1)", "", "   ",
        "${a} & 1", "regex(., ${pattern})", "regex(., '(')"
    ])
    func whatItCannotReadIsMarked(text: String) throws {
        #expect(try ChecklistExpression.read(text) == .cannotRead)
    }

    @Test func tooLongOrTooDeepIsNotReadAndReturnsAtOnce() throws {
        #expect(try ChecklistExpression.read(String(repeating: "1 + ", count: 125) + "1") == .cannotRead)  // 501
        #expect(try Self.read(String(repeating: "1 + ", count: 124) + "1") != nil)  // 497: read
        #expect(try ChecklistExpression.read(String(repeating: "(", count: 33) + "1" + String(repeating: ")",
                                                                                            count: 33))
            == .cannotRead)
        #expect(try Self.read(String(repeating: "(", count: 32) + "1" + String(repeating: ")", count: 32))
            == Self.number(1))
        #expect(try ChecklistExpression.read(String(repeating: "-", count: 400) + "1") == .cannotRead)
        #expect(try ChecklistExpression.read(String(repeating: "not(", count: 100) + "1"
                                             + String(repeating: ")", count: 100)) == .cannotRead)
    }

    @Test func manySideBySideNotNestedStayUnderTheNestingCap() throws {
        for piece in ["-1", "(1)", "int(1)"] {
            let text = Array(repeating: piece, count: 40).joined(separator: " + ")  // 40 at depth 1, none deeper

            #expect(try Self.read(text) != nil, "\(piece)")
        }
    }

    // A regex() pattern that could hang the phone

    @Test(arguments: [
        String(repeating: "a", count: 201), #"(a)\1"#, "(?<=a)b", "(?<!a)b", #"(?<x>a)\k<x>"#
    ])
    func aRiskyPatternIsRefused(pattern: String) {
        #expect(throws: ChecklistExpression.UnsafePattern.self) {
            try ChecklistExpression.read("regex(., '\(pattern)')")
        }
    }

    @Test func anOrdinaryPatternReads() throws {
        #expect(try Self.read("regex(., '^[A-Z]{2}-[0-9]{4}$')") != nil)
        #expect(try Self.read("regex(., '" + String(repeating: "a", count: 200) + "')") != nil)
    }

    @Test func theReferencesOfAnExpressionAreListed() throws {
        let node = try #require(try Self.read("if(selected(${a}, 'x'), ${b} + ${a}, .)"))

        #expect(node.references == ["a", "b"])
    }

    // In the form

    @Test func aFormWithARiskyPatternIsRefusedWithTheRowAndAnUnreadableOneIsKept() throws {
        let risky = ChecklistFormTests.question("code", "text", ["constraint": #"regex(., '(a)\1')"#])
        let unknown = ChecklistFormTests.question("name", "text", ["relevant": "jr:choice-name(., 'x') = 'y'"])

        #expect(throws: ChecklistProblem.unsafePattern(row: 2)) {
            try ChecklistForm.read(ChecklistFormTests.form([ChecklistFormTests.question("a"), risky]))
        }
        #expect(ChecklistProblem.unsafePattern(row: 2).text
            == "Row 2: this regex() pattern could make the phone hang. Keep it under 200 characters, "
            + "with no backreferences or lookbehind.")
        _ = try ChecklistForm.read(ChecklistFormTests.form([unknown]))
    }
}
