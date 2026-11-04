import Foundation

/// A whole checklist against its answers (#93): a question shows unless its own relevant, or a group's
/// around it, works out false; a hidden question is not required and its constraint is not run (the docs
/// are silent; ODK Collect behaves so); a constraint runs only on a non-empty answer; a default fills once
/// at the start. A rule the app cannot read, or that runs over its budget, never blocks: the question
/// shows, the rule is not applied, and the question is marked unchecked.
struct ChecklistRules {
    typealias Reading = ChecklistExpression.Reading

    enum Problem: Equatable, Sendable {
        case missing  // required and empty
        case refused(LocalText?)  // the constraint said no, with the form's own message
    }

    struct State: Equatable, Sendable {
        var shown: Bool
        var problem: Problem?
        var unchecked: Bool  // a rule here was not applied: it could not be read, or ran over budget

        init(shown: Bool, problem: Problem? = nil, unchecked: Bool = false) {
            (self.shown, self.problem, self.unchecked) = (shown, problem, unchecked)
        }
    }

    let form: ChecklistForm
    let now: Date
    let timeZone: TimeZone
    /// Questions and groups with a rule the app cannot read, in form order.
    let unreadable: [String]
    private let questions: [String: ChecklistQuestion]
    private let groups: [String: [String]]  // a question's groups, outermost first
    private let relevant: [String: Reading]
    private let constraint: [String: Reading]

    init(form: ChecklistForm, now: Date, timeZone: TimeZone) {
        (self.form, self.now, self.timeZone) = (form, now, timeZone)
        var walk = Walk()
        walk.visit(form.items, groups: [])
        (questions, groups, relevant, constraint, unreadable) = (walk.questions, walk.groups, walk.relevant,
                                                                  walk.constraint, walk.unreadable)
    }

    /// The defaults, filled once when the checklist starts. A default that is an expression is not filled.
    func startingAnswers() -> [String: String] {
        form.questions.reduce(into: [:]) { answers, question in
            if let value = question.defaultValue, !Self.isExpression(value) { answers[question.name] = value }
        }
    }

    func state(of name: String, in answers: [String: String]) -> State? {
        guard let question = questions[name] else { return nil }
        var unchecked = false
        for owner in (groups[name] ?? []) + [name] {
            switch holds(relevant[owner], answers, current: answers[owner] ?? "") {
            case false?: return State(shown: false)
            case nil: unchecked = true
            case true?: break
            }
        }
        let answer = answers[name] ?? ""
        guard !answer.isEmpty else {
            return State(shown: true, problem: question.required && question.kind != .note ? .missing : nil,
                         unchecked: unchecked)
        }
        switch holds(constraint[name], answers, current: answer) {
        case false?: return State(shown: true, problem: .refused(question.constraintMessage), unchecked: unchecked)
        case nil: return State(shown: true, unchecked: true)
        case true?: return State(shown: true, unchecked: unchecked)
        }
    }

    /// Every shown question with a problem.
    func problems(in answers: [String: String]) -> [String: Problem] {
        form.questions.reduce(into: [:]) { found, question in
            if let problem = state(of: question.name, in: answers)?.problem { found[question.name] = problem }
        }
    }

    /// True or false, or nil when it cannot be told (not readable, or over budget). No rule holds.
    private func holds(_ reading: Reading?, _ answers: [String: String], current: String) -> Bool? {
        guard let reading else { return true }
        guard case .read(let node) = reading else { return nil }
        let evaluator = ChecklistEvaluator(answers: answers, current: current, now: now, timeZone: timeZone)
        return try? evaluator.value(of: node).boolean
    }

    static func isExpression(_ value: String) -> Bool { value.contains("${") || value.contains("(") }

    /// Collects the form's questions, their groups and their rules, read once.
    private struct Walk {
        var questions: [String: ChecklistQuestion] = [:], groups: [String: [String]] = [:]
        var relevant: [String: Reading] = [:], constraint: [String: Reading] = [:], unreadable: [String] = []

        mutating func visit(_ items: [ChecklistItem], groups owners: [String]) {
            for item in items {
                switch item {
                case .question(let question):
                    questions[question.name] = question
                    groups[question.name] = owners
                    note(question.name, relevant: question.relevant, constraint: question.constraint,
                         dynamicDefault: question.defaultValue.map(ChecklistRules.isExpression) ?? false)
                case .group(let group):
                    note(group.name, relevant: group.relevant, constraint: nil, dynamicDefault: false)
                    visit(group.items, groups: owners + [group.name])
                }
            }
        }

        private mutating func note(_ name: String, relevant text: String?, constraint rule: String?,
                                   dynamicDefault: Bool) {
            let shown = text.map(Self.read), checked = rule.map(Self.read)
            if let shown { relevant[name] = shown }
            if let checked { constraint[name] = checked }
            if shown == .cannotRead || checked == .cannotRead || dynamicDefault { unreadable.append(name) }
        }

        private static func read(_ text: String) -> Reading { (try? ChecklistExpression.read(text)) ?? .cannotRead }
    }
}
