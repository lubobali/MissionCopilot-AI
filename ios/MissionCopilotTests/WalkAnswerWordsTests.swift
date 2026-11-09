import Foundation
import Testing
@testable import MissionCopilot

/// Plain walk answers (#161, step 7.2.8, found on the iPhone: "Edge_breaks", "2026-11-06",
/// "41.859881 -87.713197 184.4 6.8", "Evidence:1"): each answer in words by its question's type, for any form.
/// The stored, signed answer is unchanged; only what Ask and the report show.
struct WalkAnswerWordsTests {
    static let choices = ["defects": [ChecklistChoice(name: "potholes", label: LocalText(english: "Potholes",
                                                                                         french: "Nids-de-poule")),
                                      ChecklistChoice(name: "edge_breaks",
                                                      label: LocalText(english: "Broken road edges", french: nil))],
                          "yes_no": [ChecklistChoice(name: "no", label: LocalText(english: "No", french: "Non"))]]

    static func question(_ kind: QuestionKind) -> ChecklistQuestion {
        ChecklistQuestion(row: 1, name: "q", kind: kind, label: LocalText(english: "Q", french: nil), hint: nil,
                          required: false, relevant: nil, constraint: nil, constraintMessage: nil, defaultValue: nil)
    }

    static func words(_ answer: String, _ kind: QuestionKind) -> String {
        WalkAnswerWords.words(answer, question: question(kind), choices: choices)
    }

    @Test func aChoiceShowsItsLabel() {
        #expect(Self.words("edge_breaks", .selectOne("defects")) == "Broken road edges")
        #expect(Self.words("no", .selectOne("yes_no")) == "No")
        #expect(Self.words("potholes edge_breaks", .selectMultiple("defects")) == "Potholes, Broken road edges")
        #expect(Self.words("cracks", .selectOne("defects")) == "cracks", "a choice the form does not name stays")
    }

    @Test func aDateReadsLikeTheRestOfTheReport() {
        #expect(Self.words("2026-11-06", .date) == "6 Nov 2026")
        #expect(Self.words("soon", .date) == "soon")
    }

    @Test func aLocationReadsAsAPlaceAndHowSureItIs() {
        #expect(Self.words("41.859881 -87.713197 184.4 6.8", .geopoint) == "41.85988, -87.71320 (within 7 m)")
        #expect(Self.words("not a place", .geopoint) == "not a place")
    }

    @Test func aPhotoSaysItWasTaken() {
        #expect(Self.words("evidence:1", .image) == "photo taken")
    }

    @Test func textAndNumbersStayAsTyped() {
        #expect(Self.words("KN-0042", .text) == "KN-0042")
        #expect(Self.words("3.8", .decimal) == "3.8")
        #expect(Self.words("4", .integer) == "4")
    }

    /// In Ask and the report: a title that is not a question gets a colon.
    @Test func aTitleThatIsNotAQuestionGetsAColon() {
        let source = { (title: String, answer: String) in
            MissionSource(id: "walk:q", kind: .walkAnswer, title: title, text: "\(title) \(answer)",
                          origin: .walk(question: "q"))
        }

        #expect(AnswerLines.line(source("Location of the sample point", "41.85988, -87.71320 (within 7 m)")).text
                == "Your site walk: Location of the sample point: 41.85988, -87.71320 (within 7 m).")
        #expect(AnswerLines.line(source("Are side drains built?", "No")).text
                == "Your site walk: Are side drains built? No.")
    }
}
