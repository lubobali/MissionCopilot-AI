import Foundation
import Testing
@testable import MissionCopilot

/// One expression worked out the way ODK does (#93): answers are text and an empty one is "", math with
/// an empty answer is NaN and a comparison with NaN is false, < and > compare numbers, a date compares as
/// days, a select_multiple answer is names apart by spaces, and regex() searches with a 50 ms budget.
@Suite(.timeLimit(.minutes(1)))
struct ChecklistEvaluatorTests {
    static let nov3 = Date(timeIntervalSince1970: 1_793_664_000)  // 2026-11-03 00:00 UTC

    static func value(_ text: String, _ answers: [String: String] = [:], current: String = "") throws
        -> ChecklistEvaluator.Value {
        guard case .read(let node) = try ChecklistExpression.read(text) else { throw CancellationError() }
        let evaluator = ChecklistEvaluator(answers: answers, current: current, now: nov3, timeZone: .gmt)
        return try evaluator.value(of: node)
    }

    static func holds(_ text: String, _ answers: [String: String] = [:], current: String = "") throws -> Bool {
        try value(text, answers, current: current).boolean
    }

    @Test func anEmptyAnswerMakesMathNaNAndEveryComparisonWithItFalse() throws {
        #expect(try !Self.holds("${a} + 1 > 0", ["a": ""]) && Self.holds("${a} + 1 > 0", ["a": "2"]))
        #expect(try !Self.holds("${a} > 0", [:]) && !Self.holds("${a} < 0", [:]))  // unanswered: ""
        #expect(try Self.holds("${a} = ''", [:]) && Self.holds("coalesce(${a}, 0) = 0", [:]))
        #expect(try !Self.holds("number('x') = number('x')"))  // NaN is not even itself
    }

    @Test func lessAndMoreCompareNumbersNotText() throws {
        #expect(try Self.holds("${n} > 5", ["n": "10"]))  // as text "10" < "5"
        #expect(try Self.holds("1 = 1.0") && Self.holds("${a} = 'yes'", ["a": "yes"]))
        #expect(try Self.holds("${n} = 10", ["n": "10.0"]))  // a number on one side: numbers
        #expect(try Self.holds("(1 > 0) = (2 > 1)") && !Self.holds("'a' = 'b'"))
        #expect(try Self.holds("(1 > 0) = 'x'") && Self.holds("${a} = (1 > 2)", [:]))  // as true or false
    }

    @Test func mathFollowsXPath() throws {
        #expect(try Self.value("7 mod 3") == .number(1) && Self.value("7 div 2") == .number(3.5))
        #expect(try Self.value("5 mod 3") == .number(2) && Self.value("-5 mod 3") == .number(-2))  // sign of the left
        #expect(try Self.holds("1 div 0 > 1000000") && Self.value("-(2 * 3) + 1") == .number(-5))
        #expect(try Self.value("int(-2.7)") == .number(-2) && Self.value("int(2.7)") == .number(2))
    }

    @Test func aMultipleChoiceAnswerIsNamesApartBySpaces() throws {
        let answers = ["m": "a b  c"]

        #expect(try Self.holds("selected(${m}, 'b')", answers) && !Self.holds("selected(${m}, 'd')", answers))
        #expect(try Self.value("count-selected(${m})", answers) == .number(3))
        #expect(try Self.value("count-selected(${m})", [:]) == .number(0))
        #expect(try !Self.holds("selected(${m}, 'ab')", ["m": "abc def"]))  // a whole name, never a part
    }

    @Test func theOtherFunctions() throws {
        #expect(try Self.value("string-length(.)", current: "Kandor") == .number(6))
        #expect(try Self.value("string-length('e\u{301}')") == .number(1))  // one letter as a person counts
        #expect(try Self.value("if(${a} = 'yes', 'big', 'small')", ["a": "yes"]) == .text("big"))
        #expect(try Self.value("coalesce(${a}, 'none')", ["a": "x"]) == .text("x"))
        #expect(try Self.holds("not(${a} = 'yes')", ["a": "no"]) && !Self.holds("not(1)"))
        #expect(try Self.holds("'0' and 1") && !Self.holds("'' or 0"))  // text: true when not empty
    }

    @Test func aDateComparesAsDaysAndTodayIsThePhonesDay() throws {
        #expect(try Self.value("today()") == .text("2026-11-03"))
        #expect(try Self.holds(". <= today()", current: "2026-11-02"))
        #expect(try !Self.holds(". <= today()", current: "2026-11-04"))
        #expect(try !Self.holds(". <= today()", current: ""))
        #expect(try Self.value("number('1970-01-02')") == .number(1))
        let chicago = ChecklistEvaluator(answers: [:], current: "", now: Self.nov3,
                                         timeZone: try #require(TimeZone(identifier: "America/Chicago")))
        #expect(try chicago.value(of: .call(.today, [])) == .text("2026-11-02"))  // still the evening before
    }

    // regex()

    @Test func regexSearchesTheAnswer() throws {
        #expect(try Self.holds("regex(., '^[A-Z]{2}-[0-9]{4}$')", current: "KN-0042"))
        #expect(try !Self.holds("regex(., '^[A-Z]{2}-[0-9]{4}$')", current: "kn-1"))
        #expect(try Self.holds("regex('abc', 'b')"))  // found anywhere, as on KoBo's web forms
    }

    @Test func aPatternThatWouldRunForeverIsStoppedWithinItsBudget() throws {
        let start = Date()

        #expect(throws: ChecklistEvaluator.CannotTell.self) {
            try Self.holds("regex(., '(a+)+$')", current: String(repeating: "a", count: 32) + "!")
        }
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test func aRegexOnAVeryLongAnswerIsNotRun() {
        #expect(throws: ChecklistEvaluator.CannotTell.self) {
            try Self.holds("regex(., 'a')", current: String(repeating: "a", count: 1001))
        }
    }
}
