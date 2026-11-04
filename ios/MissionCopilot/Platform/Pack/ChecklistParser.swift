import Foundation

/// Reads tokens into a ChecklistExpression tree, lowest binding first (XPath 1.0): or, and, = and !=,
/// < <= > >=, + and -, * div mod, then a minus in front, then a value, a ${name}, ".", a function call or
/// parentheses. Every parenthesis, call and minus in front counts toward the nesting cap.
struct ChecklistParser {
    struct CannotRead: Error {}
    typealias Node = ChecklistExpression.Node

    private static let levels: [[String: ChecklistExpression.Operator]] = [
        ["or": .either], ["and": .both], ["=": .equal, "!=": .notEqual],
        ["<": .less, "<=": .lessOrEqual, ">": .greater, ">=": .greaterOrEqual],
        ["+": .plus, "-": .minus], ["*": .times, "div": .divide, "mod": .modulo]
    ]

    private let tokens: [Token]
    private var position = 0
    private var depth = 0

    init(tokens: [Token]) { self.tokens = tokens }

    /// The whole expression; tokens left over mean it cannot be read.
    mutating func all() throws(CannotRead) -> Node {
        let node = try binary(0)
        guard position == tokens.count else { throw CannotRead() }
        return node
    }

    private var current: Token? { position < tokens.count ? tokens[position] : nil }

    private mutating func take(_ text: String) -> Bool {
        guard current?.text == text else { return false }
        position += 1
        return true
    }

    private mutating func enter() throws(CannotRead) {
        depth += 1
        guard depth <= ChecklistExpression.maxDepth else { throw CannotRead() }
    }

    private mutating func binary(_ level: Int) throws(CannotRead) -> Node {
        guard level < Self.levels.count else { return try unary() }
        var left = try binary(level + 1)
        while let text = current?.text, let operation = Self.levels[level][text] {
            position += 1
            left = .binary(operation, left, try binary(level + 1))
        }
        return left
    }

    private mutating func unary() throws(CannotRead) -> Node {
        guard take("-") else { return try primary() }
        try enter()
        defer { depth -= 1 }
        return .negative(try unary())
    }

    private mutating func primary() throws(CannotRead) -> Node {
        guard let token = current else { throw CannotRead() }
        position += 1
        switch token {
        case .number(let value): return .number(value)
        case .string(let text): return .string(text)
        case .reference(let name): return .reference(name)
        case .dot: return .current
        case .symbol("("):
            try enter()
            defer { depth -= 1 }
            let inner = try binary(0)
            guard take(")") else { throw CannotRead() }
            return inner
        case .word(let name):
            guard let function = ChecklistExpression.Function(rawValue: name), take("(") else { throw CannotRead() }
            return .call(function, try arguments(of: function))
        default: throw CannotRead()
        }
    }

    private mutating func arguments(of function: ChecklistExpression.Function) throws(CannotRead) -> [Node] {
        try enter()
        defer { depth -= 1 }
        var found: [Node] = []
        if !take(")") {
            repeat { found.append(try binary(0)) } while take(",")
            guard take(")") else { throw CannotRead() }
        }
        guard function.arguments.contains(found.count) else { throw CannotRead() }
        return found
    }
}
