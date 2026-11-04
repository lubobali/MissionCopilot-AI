import Foundation

/// Works out one checklist expression the way ODK does (#93, XPath 1.0 rules): answers are text and an
/// unanswered question is ""; math with an empty answer is NaN and a comparison with NaN is false; < and >
/// compare numbers; = compares as true or false if one side is, as numbers if one side is, else as text; a
/// date "YYYY-MM-DD" counts as days since 1970 wherever a number is needed; a select_multiple answer is
/// choice names apart by spaces; regex() searches the answer (as KoBo's web forms do) and stops after 50 ms.
struct ChecklistEvaluator {
    typealias Node = ChecklistExpression.Node

    /// The answer cannot be known: a pattern ran over its budget, or the text was too long to search.
    struct CannotTell: Error, Equatable {}

    static let budget: TimeInterval = 0.05
    static let maxSearched = 1_000

    enum Value: Equatable, Sendable {
        case text(String), number(Double), truth(Bool)

        var boolean: Bool {
            switch self {
            case .truth(let truth): truth
            case .number(let number): number != 0 && !number.isNaN
            case .text(let text): !text.isEmpty
            }
        }

        var number: Double {
            switch self {
            case .truth(let truth): truth ? 1 : 0
            case .number(let number): number
            case .text(let text): Self.number(text)
            }
        }

        var text: String {
            switch self {
            case .truth(let truth): truth ? "true" : "false"
            case .number(let number) where number.rounded() == number && number.isFinite: String(Int(number))
            case .number(let number): number.isNaN ? "NaN" : String(number)
            case .text(let text): text
            }
        }

        static func number(_ text: String) -> Double {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let day = ChecklistEvaluator.days(trimmed) { return day }
            return Double(trimmed) ?? .nan
        }
    }

    let answers: [String: String]
    let current: String
    let now: Date
    let timeZone: TimeZone

    func value(of node: Node) throws(CannotTell) -> Value {
        switch node {
        case .number(let number): .number(number)
        case .string(let text): .text(text)
        case .reference(let name): .text(answers[name] ?? "")
        case .current: .text(current)
        case .negative(let inner): .number(-(try value(of: inner).number))
        case .binary(let operation, let left, let right):
            binary(operation, try value(of: left), try value(of: right))
        case .call(let function, let arguments): try call(function, arguments)
        }
    }

    private static let comparisons: [ChecklistExpression.Operator: @Sendable (Double, Double) -> Bool] = [
        .less: { $0 < $1 }, .lessOrEqual: { $0 <= $1 }, .greater: { $0 > $1 }, .greaterOrEqual: { $0 >= $1 }
    ]
    private static let arithmetic: [ChecklistExpression.Operator: @Sendable (Double, Double) -> Double] = [
        .plus: { $0 + $1 }, .minus: { $0 - $1 }, .times: { $0 * $1 }, .divide: { $0 / $1 },
        .modulo: { $0.truncatingRemainder(dividingBy: $1) }
    ]

    private func binary(_ operation: ChecklistExpression.Operator, _ left: Value, _ right: Value) -> Value {
        switch operation {
        case .either: return .truth(left.boolean || right.boolean)
        case .both: return .truth(left.boolean && right.boolean)
        case .equal: return .truth(Self.equal(left, right))
        case .notEqual: return .truth(!Self.equal(left, right))
        default:
            if let compare = Self.comparisons[operation] { return .truth(compare(left.number, right.number)) }
            return .number(Self.arithmetic[operation].map { $0(left.number, right.number) } ?? .nan)
        }
    }

    private static func equal(_ left: Value, _ right: Value) -> Bool {
        switch (left, right) {
        case (.truth, _), (_, .truth): left.boolean == right.boolean
        case (.number, _), (_, .number): left.number == right.number
        default: left.text == right.text
        }
    }

    private func call(_ function: ChecklistExpression.Function, _ arguments: [Node]) throws(CannotTell) -> Value {
        var values: [Value] = []
        for argument in arguments { values.append(try value(of: argument)) }
        let first = values.first ?? .text(current)
        switch function {
        case .not: return .truth(!first.boolean)
        case .regex: return .truth(try Self.search(first.text, for: values[1].text))
        case .choose: return values[0].boolean ? values[1] : values[2]
        case .coalesce: return first.text.isEmpty ? values[1] : first
        case .today: return .text(Self.day(now, in: timeZone))
        default: return Self.counted(function, first, values)
        }
    }

    /// The functions that give a number, or say whether a choice is selected.
    private static func counted(_ function: ChecklistExpression.Function, _ first: Value, _ values: [Value]) -> Value {
        switch function {
        case .selected: .truth(names(first.text).contains(values[1].text.trimmingCharacters(in: .whitespaces)))
        case .countSelected: .number(Double(names(first.text).count))
        case .stringLength: .number(Double(first.text.count))
        case .int: .number(first.number.rounded(.towardZero))
        default: .number(first.number)
        }
    }

    private static func names(_ text: String) -> [String] { text.split(separator: " ").map(String.init) }

    /// Searches with a time budget: the match reports progress while it runs, and is stopped once the
    /// budget is spent, so a pattern that would run for minutes ends in 50 ms as "cannot tell".
    static func search(_ text: String, for pattern: String) throws(CannotTell) -> Bool {
        guard text.unicodeScalars.count <= maxSearched, let regex = try? NSRegularExpression(pattern: pattern) else {
            throw CannotTell()
        }
        let deadline = Date().addingTimeInterval(budget)
        var found = false, stopped = false
        let range = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, options: [.reportProgress], range: range) { match, _, stop in
            if match != nil { found = true } else if Date() > deadline { stopped = true } else { return }
            stop.pointee = true
        }
        if stopped, !found { throw CannotTell() }
        return found
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// "YYYY-MM-DD" as days since 1970-01-01, or nil when it is not a date.
    static func days(_ text: String) -> Double? {
        guard let match = text.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/), let year = Int(match.1),
              let month = Int(match.2), let day = Int(match.3),
              let date = utc.date(from: DateComponents(year: year, month: month, day: day)),
              utc.component(.day, from: date) == day else { return nil }
        return (date.timeIntervalSince1970 / 86_400).rounded()
    }

    static func day(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
