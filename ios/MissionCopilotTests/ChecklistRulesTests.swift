import Foundation
import Testing
@testable import MissionCopilot

/// A whole checklist against its answers (#93): a question shows unless its relevant (or a group's
/// around it) says no; a hidden question is not required and its constraint is not run; a constraint runs
/// only on a non-empty answer; a default fills once at the start. A rule the app cannot read or that runs
/// over its budget never blocks: the question shows, the rule is not applied, and the question is marked.
@Suite(.timeLimit(.minutes(1)))
struct ChecklistRulesTests {
    typealias Question = ChecklistFormTests

    static func rules(_ survey: [[String: Any]]) throws -> ChecklistRules {
        ChecklistRules(form: try ChecklistForm.read(Question.form(survey)), now: ChecklistEvaluatorTests.nov3,
                       timeZone: .gmt)
    }

    @Test(.needsRepoFiles) func theKandorWidthMustBeBetween0And20Metres() throws {
        let form = try ChecklistForm.read(try #require(PackSectionsTests.files["forms/road-checklist.json"]))
        let rules = ChecklistRules(form: form, now: ChecklistEvaluatorTests.nov3, timeZone: .gmt)

        #expect(rules.state(of: "road_width_m", in: ["road_width_m": "4.9"]) == .init(shown: true))
        let message = try #require(form.questions.first { $0.name == "road_width_m" }?.constraintMessage)
        #expect(rules.state(of: "road_width_m", in: ["road_width_m": "25"])
            == .init(shown: true, problem: .refused(message)))
        #expect(rules.state(of: "road_width_m", in: ["road_width_m": "0"])?.problem == .refused(message))
        #expect(rules.state(of: "road_width_m", in: [:])?.problem == .missing)
        #expect(rules.state(of: "sample_photo", in: [:]) == .init(shown: true))  // not required
    }

    @Test(.needsRepoFiles) func theKandorBridgeQuestionsShowOnlyOnceTheBridgeHasStarted() throws {
        let rules = try Self.kandor()

        #expect(rules.state(of: "piers_built", in: ["bridge_started": "no"]) == .init(shown: false))
        #expect(rules.state(of: "piers_built", in: ["bridge_started": "yes"])?.problem == .missing)
        #expect(rules.state(of: "piers_built", in: ["bridge_started": "yes", "piers_built": "5"])?.problem
            != nil)
        #expect(rules.state(of: "bridge_work_started", in: ["bridge_started": "yes",
                                                            "bridge_work_started": "2026-11-04"])?.problem != nil)
        #expect(rules.state(of: "bridge_work_started", in: ["bridge_started": "yes",
                                                            "bridge_work_started": "2026-07-01"])?.problem == nil)
    }

    @Test(.needsRepoFiles) func theKandorDefectsAndSiteBoardAreChecked() throws {
        let rules = try Self.kandor()

        #expect(rules.state(of: "defects", in: ["defects": "none potholes"])?.problem != nil)
        #expect(rules.state(of: "defects", in: ["defects": "potholes edge_breaks"])?.problem == nil)
        #expect(rules.state(of: "board_ref", in: ["board_ref": "KN-0042"]) == .init(shown: true))
        #expect(rules.state(of: "board_ref", in: ["board_ref": "kn-42"])?.problem != nil)
        #expect(rules.unreadable.isEmpty)  // every rule of the real form is read
    }

    static func kandor() throws -> ChecklistRules {
        let form = try ChecklistForm.read(try #require(PackSectionsTests.files["forms/road-checklist.json"]))
        return ChecklistRules(form: form, now: ChecklistEvaluatorTests.nov3, timeZone: .gmt)
    }

    @Test func aHiddenQuestionIsNotRequiredAndItsConstraintIsNotRun() throws {
        let rules = try Self.rules([
            Question.question("started", "select_one yes_no"),
            Question.question("deck", "integer", ["relevant": "${started} = 'yes'", "required": "yes",
                                                  "constraint": ". > 0"])
        ])

        #expect(rules.state(of: "deck", in: ["started": "no", "deck": "-4"]) == .init(shown: false))
        #expect(rules.state(of: "deck", in: ["started": "yes"])?.problem == .missing)
        #expect(rules.state(of: "deck", in: ["started": "yes", "deck": "-4"])?.problem == .refused(nil))
    }

    @Test func aGroupHidesEverythingInsideItNestedToo() throws {
        let rules = try Self.rules([
            Question.question("started", "select_one yes_no"),
            Question.question("bridge", "begin_group", ["relevant": "${started} = 'yes'"]),
            Question.question("inner", "begin_group"), Question.question("deck", "text", ["required": "yes"]),
            Question.end, Question.end
        ])

        #expect(rules.state(of: "deck", in: ["started": "no"]) == .init(shown: false))
        #expect(rules.state(of: "deck", in: ["started": "yes"])?.problem == .missing)
        #expect(rules.problems(in: ["started": "no"]).isEmpty)
        #expect(rules.problems(in: ["started": "yes"]) == ["deck": .missing])
    }

    @Test func aConstraintRunsOnlyOnAnAnswer() throws {
        let rules = try Self.rules([Question.question("km", "decimal", ["constraint": ". > 0"])])

        #expect(rules.state(of: "km", in: [:]) == .init(shown: true))
        #expect(rules.state(of: "km", in: ["km": "-1"])?.problem == .refused(nil))
    }

    @Test func aRuleTheAppCannotReadShowsTheQuestionAndIsMarked() throws {
        let rules = try Self.rules([
            Question.question("a", "text", ["relevant": "jr:choice-name(., 'x') = 'y'", "required": "yes"]),
            Question.question("b", "text", ["constraint": "now() > 1"])
        ])

        #expect(rules.state(of: "a", in: [:]) == .init(shown: true, problem: .missing, unchecked: true))
        #expect(rules.state(of: "b", in: ["b": "x"]) == .init(shown: true, unchecked: true))
        #expect(rules.unreadable == ["a", "b"])
    }

    @Test func aPatternOverItsBudgetIsNotAppliedAndIsMarked() throws {
        let rules = try Self.rules([Question.question("code", "text", ["constraint": "regex(., '(a+)+$')"])])

        let state = rules.state(of: "code", in: ["code": String(repeating: "a", count: 32) + "!"])

        #expect(state == .init(shown: true, unchecked: true))
    }

    @Test func aDefaultFillsAtTheStartAndAnExpressionDefaultIsMarkedNotFilled() throws {
        let rules = try Self.rules([
            Question.question("lanes", "integer", ["default": "2"]),
            Question.question("who", "text", ["default": "concat('a', 'b')"]), Question.question("none")
        ])

        #expect(rules.startingAnswers() == ["lanes": "2"])
        #expect(rules.unreadable == ["who"])
    }

    @Test func aNoteMarkedRequiredIsNeverMissing() throws {
        let rules = try Self.rules([Question.question("intro", "note", ["required": "yes"])])

        #expect(rules.state(of: "intro", in: [:]) == .init(shown: true))
    }

    @Test func anUnknownQuestionHasNoState() throws {
        #expect(try Self.rules([Question.question("a")]).state(of: "nope", in: [:]) == nil)
    }
}
