import Foundation

/// A site walk's rules (#129): the pack's checklist and agreed actions against what the officer has
/// answered and checked. Pure, so every case is tested; `SiteWalkModel` saves and loads it. A walk may
/// finish when every shown question that needs an answer has a good one and every agreed action has what
/// was seen ("could not check" counts); an optional question, such as the photo, may stay empty.
struct SiteWalk {
    struct Progress: Equatable, Sendable {
        let answered: Int, questions: Int, actionsChecked: Int, actions: Int
    }

    /// What still stops the finish, in the walk's order: questions in form order, then actions.
    enum Missing: Equatable, Sendable {
        case question(String), action(String)
    }

    let form: ChecklistForm
    let actions: AgreedActions
    let answers: [String: String]
    let checks: [String: ActionCheck]
    let language: String
    private let rules: ChecklistRules

    init(form: ChecklistForm, actions: AgreedActions, answers: [String: String], checks: [String: ActionCheck],
         language: String, now: Date, timeZone: TimeZone) {
        (self.form, self.actions, self.answers, self.checks, self.language) = (form, actions, answers, checks,
                                                                                language)
        rules = ChecklistRules(form: form, now: now, timeZone: timeZone)
    }

    /// The questions on screen that take an answer (a note only shows text), in form order.
    var questions: [ChecklistQuestion] {
        form.questions.filter { $0.kind != .note && isShown($0.name) }
    }

    func isShown(_ question: String) -> Bool { rules.state(of: question, in: answers)?.shown ?? false }

    var progress: Progress {
        let shown = questions
        return Progress(answered: shown.filter { !(answers[$0.name] ?? "").isEmpty }.count, questions: shown.count,
                        actionsChecked: actions.actions.filter { checks[$0.key] != nil }.count,
                        actions: actions.actions.count)
    }

    var missing: [Missing] {
        let questions = questions.filter { rules.state(of: $0.name, in: answers)?.problem != nil }
        let unchecked = actions.actions.filter { checks[$0.key] == nil }
        return questions.map { .question($0.name) } + unchecked.map { .action($0.key) }
    }

    var canFinish: Bool { missing.isEmpty }

    /// What is wrong with an answer, in the walk's language; nothing for an empty one (a fresh walk is not a
    /// wall of red: what is left shows in the finish list).
    func problem(of question: String) -> String? {
        guard case .refused(let message)? = rules.state(of: question, in: answers)?.problem else { return nil }
        return message?.text(for: language) ?? (language == "fr" ? "Cette réponse n'est pas acceptée."
                                                                   : "This answer is not accepted.")
    }

    /// French when the phone's first language is French and the form has it; English otherwise.
    static func startingLanguage(preferred: [String], formHasFrench: Bool) -> String {
        formHasFrench && (preferred.first ?? "").hasPrefix("fr") ? "fr" : "en"
    }
}
