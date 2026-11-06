import Foundation
import Testing
@testable import MissionCopilot

/// The site walk's rules (#129, step 6.2.3), on the real Kandor pack: which questions count, the
/// progress, the language, and when the walk may finish.
struct SiteWalkTests {
    static let walkDay = ISO8601DateFormatter().date(from: "2026-11-10T09:00:00Z") ?? .distantPast

    static func kandor() throws -> (ChecklistForm, AgreedActions) {
        let form = try ChecklistForm.read(try #require(PackSectionsTests.files["forms/road-checklist.json"]))
        let actions = try AgreedActions.read(try #require(PackSectionsTests.files[AgreedActions.path]))
        return (form, actions)
    }

    /// A walk on the real pack with these answers and checks.
    static func walk(_ answers: [String: String] = [:], checks: [String: ActionCheck] = [:],
                     language: String = "en") throws -> SiteWalk {
        let (form, actions) = try kandor()
        return SiteWalk(form: form, actions: actions, answers: answers, checks: checks, language: language,
                        now: walkDay, timeZone: .gmt)
    }

    /// Everything the road checklist requires while the bridge has not started, and every action checked.
    static func complete() throws -> ([String: String], [String: ActionCheck]) {
        let (_, actions) = try kandor()
        let answers = ["bridge_started": "no", "road_width_m": "6.2", "drainage_present": "yes",
                       "defects": "potholes", "sample_point": "1.06 1.05 0 4"]
        let checks = Dictionary(uniqueKeysWithValues: actions.actions.map { ($0.key, ActionCheck(seen: .notStarted,
                                                                                                  note: nil)) })
        return (answers, checks)
    }

    @Test func progressCountsTheShownQuestionsThatTakeAnAnswer() throws {
        // The bridge group is hidden until work started; the note takes no answer.
        let start = try Self.walk()
        #expect(start.progress == SiteWalk.Progress(answered: 0, questions: 7, actionsChecked: 0, actions: 3))

        let bridge = try Self.walk(["bridge_started": "yes", "road_width_m": "6.2"])
        #expect(bridge.progress == SiteWalk.Progress(answered: 2, questions: 9, actionsChecked: 0, actions: 3))
    }

    @Test func aCompleteWalkMayFinishWithTheOptionalPhotoEmpty() throws {
        let (answers, checks) = try Self.complete()

        let walk = try Self.walk(answers, checks: checks)

        #expect(walk.missing.isEmpty)
        #expect(walk.canFinish)
    }

    @Test func aRequiredQuestionLeftEmptyStopsTheFinishAndIsNamedInFormOrder() throws {
        var (answers, checks) = try Self.complete()
        answers["road_width_m"] = nil
        answers["sample_point"] = nil

        let walk = try Self.walk(answers, checks: checks)

        #expect(!walk.canFinish)
        #expect(walk.missing == [.question("road_width_m"), .question("sample_point")])
    }

    @Test func aBrokenRuleStopsTheFinishWithTheFormsOwnMessage() throws {
        var (answers, checks) = try Self.complete()
        answers["road_width_m"] = "25"

        let english = try Self.walk(answers, checks: checks)
        let french = try Self.walk(answers, checks: checks, language: "fr")

        #expect(!english.canFinish)
        #expect(english.problem(of: "road_width_m") == "A road width is between 0 and 20 metres")
        #expect(french.problem(of: "road_width_m") == "Une largeur de route est comprise entre 0 et 20 mètres")
    }

    @Test func everyAgreedActionNeedsWhatWasSeenEvenCouldNotCheck() throws {
        let (answers, checks) = try Self.complete()
        let (_, actions) = try Self.kandor()
        var oneShort = checks
        oneShort[actions.actions[1].key] = nil

        let walk = try Self.walk(answers, checks: oneShort)

        #expect(!walk.canFinish)
        #expect(walk.missing == [.action(actions.actions[1].key)])
        var couldNotCheck = checks
        couldNotCheck[actions.actions[1].key] = ActionCheck(seen: .couldNotCheck, note: "Site closed")
        #expect(try Self.walk(answers, checks: couldNotCheck).canFinish)
    }

    @Test func aHiddenQuestionNeitherCountsNorStopsTheFinish() throws {
        // Answered while the bridge had started, then changed to "no": the bridge questions hide.
        var (answers, checks) = try Self.complete()
        answers["piers_built"] = "9"  // breaks its rule, but it is hidden now

        let walk = try Self.walk(answers, checks: checks)

        #expect(walk.canFinish)
        #expect(walk.progress.questions == 7)
    }

    @Test func emptyQuestionsHaveNoProblemShownUntilTheyAreAnswered() throws {
        // A fresh walk is not a wall of red: "missing" shows only in the finish list.
        let walk = try Self.walk()

        #expect(walk.problem(of: "road_width_m") == nil)
        #expect(try Self.walk(["road_width_m": "0"]).problem(of: "road_width_m") != nil)
    }

    @Test(arguments: [(["fr-FR", "en-US"], true, "fr"), (["en-US", "fr-FR"], true, "en"), (["fr-FR"], false, "en")])
    func theWalkStartsInThePhonesLanguageWhenTheFormHasIt(preferred: [String], french: Bool, language: String) {
        #expect(SiteWalk.startingLanguage(preferred: preferred, formHasFrench: french) == language)
    }
}
