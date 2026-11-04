import Foundation

/// A checklist expression (relevant, constraint, default) read into a tree (#93, threat T54): the ODK
/// subset a site checklist uses, with XPath's order of operations, by a parser of our own that never runs
/// anything as code. Caps on length and nesting keep every read short. What it cannot read is marked
/// "cannot read" (the question then shows and the check is not enforced, 93.4); only a regex() pattern that
/// could hang the phone is refused, because a crafted form must not be able to stop the app.
enum ChecklistExpression {
    static let maxLength = 500
    static let maxDepth = 32
    static let maxPattern = 200

    enum Reading: Equatable, Sendable { case read(Node), cannotRead }

    /// A regex() pattern too long, or with backreferences or lookbehind (the parts that make a match slow).
    struct UnsafePattern: Error, Equatable {}

    enum Operator: Sendable {
        case either, both, equal, notEqual, less, lessOrEqual, greater, greaterOrEqual
        case plus, minus, times, divide, modulo
    }

    enum Function: String, Sendable {
        case not, selected, countSelected = "count-selected", stringLength = "string-length", regex, choose = "if"
        case coalesce, number, int, today

        var arguments: ClosedRange<Int> {
            switch self {
            case .today: 0...0
            case .stringLength: 0...1
            case .not, .countSelected, .number, .int: 1...1
            case .selected, .regex, .coalesce: 2...2
            case .choose: 3...3
            }
        }
    }

    indirect enum Node: Equatable, Sendable {
        case number(Double), string(String), reference(String), current
        case negative(Node)
        case binary(Operator, Node, Node)
        case call(Function, [Node])

        /// The question names it uses, each once, in the order they first appear.
        var references: [String] {
            var seen: [String] = []
            visit { if case .reference(let name) = $0, !seen.contains(name) { seen.append(name) } }
            return seen
        }

        func visit(_ body: (Node) -> Void) {
            body(self)
            switch self {
            case .negative(let inner): inner.visit(body)
            case .binary(_, let left, let right): left.visit(body); right.visit(body)
            case .call(_, let arguments): arguments.forEach { $0.visit(body) }
            default: break
            }
        }
    }

    static func read(_ text: String) throws(UnsafePattern) -> Reading {
        guard text.unicodeScalars.count <= maxLength, let tokens = Token.split(text) else { return .cannotRead }
        var parser = ChecklistParser(tokens: tokens)
        guard let node = try? parser.all() else { return .cannotRead }
        var readable = true
        var unsafe = false
        node.visit { item in
            guard case .call(.regex, let arguments) = item else { return }
            guard case .string(let pattern)? = arguments.last else { readable = false; return }
            if pattern.unicodeScalars.count > maxPattern || risky(pattern) { unsafe = true }
            if (try? NSRegularExpression(pattern: pattern)) == nil { readable = false }
        }
        if unsafe { throw UnsafePattern() }
        return readable ? .read(node) : .cannotRead
    }

    /// Backreferences (\1 to \9, \k) and lookbehind. A doubled backslash before a digit is refused too: on
    /// the safe side.
    private static func risky(_ pattern: String) -> Bool {
        pattern.contains(/\\[1-9]|\\k|\(\?<[=!]/)
    }
}

/// The pieces of an expression.
enum Token: Equatable, Sendable {
    case number(Double), string(String), reference(String), dot, word(String), symbol(String)

    /// The text an operator token stands for, for matching ("or", "<=", ...).
    var text: String? {
        switch self {
        case .word(let word): word
        case .symbol(let symbol): symbol
        default: nil
        }
    }

    /// The tokens of a text, or nil for anything outside the subset.
    static func split(_ text: String) -> [Token]? {
        var tokens: [Token] = []
        var rest = Substring(text)
        while let first = rest.first {
            if first.isWhitespace { rest.removeFirst(); continue }
            guard let (token, length) = next(rest) else { return nil }
            tokens.append(token)
            rest.removeFirst(length)
        }
        return tokens.isEmpty ? nil : tokens
    }

    private static func next(_ rest: Substring) -> (Token, Int)? {
        if let match = rest.prefixMatch(of: /\$\{([a-z][a-z0-9_]*)\}/) {
            return (.reference(String(match.1)), match.0.count)
        }
        if let match = rest.prefixMatch(of: /[0-9]+(\.[0-9]*)?|\.[0-9]+/), let value = Double(match.0) {
            return (.number(value), match.0.count)
        }
        if let match = rest.prefixMatch(of: /'([^']*)'|"([^"]*)"/) {
            return (.string(String(match.1 ?? match.2 ?? "")), match.0.count)
        }
        if rest.first == "." { return (.dot, 1) }
        if let match = rest.prefixMatch(of: /[A-Za-z_][A-Za-z0-9_:\-]*/) {
            return (.word(String(match.0)), match.0.count)
        }
        if let match = rest.prefixMatch(of: /!=|<=|>=|[=<>+\-*(),]/) {
            return (.symbol(String(match.0)), match.0.count)
        }
        return nil
    }
}
