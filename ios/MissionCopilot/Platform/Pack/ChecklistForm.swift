import Foundation

/// A text of the form in English, and in French when the form has it (#93: the two languages tested).
struct LocalText: Equatable, Sendable {
    let english: String
    let french: String?

    /// French on a phone set to French when the form has it; English otherwise.
    func text(for language: String) -> String { language == "fr" ? french ?? english : english }
}

/// The question types the app reads (XLSForm names; a select names its choice list).
enum QuestionKind: Equatable, Sendable {
    case text, integer, decimal, note, date, geopoint, image
    case selectOne(String), selectMultiple(String)
}

/// One question as the form says it; the expressions stay text until the expression reader (93.3).
struct ChecklistQuestion: Equatable, Sendable {
    let row: Int
    let name: String
    let kind: QuestionKind
    let label: LocalText
    let hint: LocalText?
    let required: Bool
    let relevant: String?
    let constraint: String?
    let constraintMessage: LocalText?
    let defaultValue: String?
}

/// A group of questions shown or hidden together by its own relevant.
struct ChecklistGroup: Equatable, Sendable {
    let row: Int
    let name: String
    let label: LocalText
    let relevant: String?
    let items: [ChecklistItem]
}

indirect enum ChecklistItem: Equatable, Sendable {
    case question(ChecklistQuestion)
    case group(ChecklistGroup)
}

struct ChecklistChoice: Equatable, Sendable {
    let name: String
    let label: LocalText
}

/// A site checklist from a mission pack (#93, threat T54), read from KoBo's flat JSON rows into
/// questions and nested groups. Read only after the pack's schema check; a form nobody could fill is
/// refused here with the row to fix. Filling it on site is Phase 6.
struct ChecklistForm: Equatable, Sendable {
    static let maxDepth = 3

    let formId: String
    let title: String
    let version: String
    let items: [ChecklistItem]
    let choices: [String: [ChecklistChoice]]
    let hasFrench: Bool

    /// Every question in form order, groups opened.
    var questions: [ChecklistQuestion] { Self.questions(in: items) }

    private static func questions(in items: [ChecklistItem]) -> [ChecklistQuestion] {
        items.flatMap { item -> [ChecklistQuestion] in
            switch item {
            case .question(let question): [question]
            case .group(let group): questions(in: group.items)
            }
        }
    }
}

/// What the pack summary says about the checklist: how many questions (notes are not), and whether it
/// has French.
struct ChecklistSummary: Equatable, Sendable {
    let questions: Int
    let french: Bool

    init(questions: Int, french: Bool) { (self.questions, self.french) = (questions, french) }

    init(_ form: ChecklistForm) {
        self.init(questions: form.questions.filter { $0.kind != .note }.count, french: form.hasFrench)
    }
}

/// Why a checklist was refused, with the survey row to fix.
enum ChecklistProblem: Error, Equatable {
    case unreadable
    case unknownType(row: Int, String)
    case duplicateName(row: Int, String)
    case noSuchList(row: Int, String)
    case noList(row: Int)
    case unbalancedGroup(row: Int)
    case tooDeep(row: Int)
    case unknownReference(row: Int, String)
    case duplicateChoice(list: String, String)
    case unsafePattern(row: Int)

    /// For the admin who wrote the form.
    var text: String {
        switch self {
        case .unreadable: "This file is not a checklist the app can read."
        case .unknownType(let row, let type): "Row \(row): the question type \"\(type)\" is not supported."
        case .duplicateName(let row, let name): "Row \(row): the name \"\(name)\" is used twice."
        case .noSuchList(let row, let list): "Row \(row): there is no choice list named \"\(list)\"."
        case .noList(let row): "Row \(row): a select question needs exactly one choice list."
        case .unbalancedGroup(let row): "Row \(row): a group is started or ended without its pair."
        case .tooDeep(let row): "Row \(row): groups can be at most \(ChecklistForm.maxDepth) deep."
        case .unknownReference(let row, let name): "Row \(row): ${\(name)} names no question in this form."
        case .duplicateChoice(let list, let name): "The choice list \"\(list)\" has \"\(name)\" twice."
        case .unsafePattern(let row):
            "Row \(row): this regex() pattern could make the phone hang. Keep it under "
                + "\(ChecklistExpression.maxPattern) characters, with no backreferences or lookbehind."
        }
    }
}
