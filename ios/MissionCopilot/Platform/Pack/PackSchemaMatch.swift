import Foundation

/// How PackSchema applies each keyword, as JSON Schema 2020-12 does: a keyword about strings says nothing
/// about a number, "integer" is a number with no fraction, a pattern is searched for, not matched whole, and
/// a length is counted in Unicode code points (as the reference does), not in letters as Swift counts them.
extension PackSchema {
    static func matches(_ value: JSONValue, _ schema: JSONValue) -> Bool {
        switch schema {
        case .bool(let allowed): return allowed
        case .object(let keywords):
            return typeMatches(value, keywords) && valueMatches(value, keywords) && stringMatches(value, keywords)
                && numberMatches(value, keywords) && arrayMatches(value, keywords)
                && objectMatches(value, keywords) && oneOfMatches(value, keywords)
        default: return false
        }
    }

    private static func typeMatches(_ value: JSONValue, _ keywords: [String: JSONValue]) -> Bool {
        switch keywords["type"] {
        case nil: true
        case .string(let name): value.isType(name)
        case .array(let names): names.contains { if case .string(let name) = $0 { value.isType(name) } else { false } }
        default: false
        }
    }

    private static func valueMatches(_ value: JSONValue, _ keywords: [String: JSONValue]) -> Bool {
        if let fixed = keywords["const"], fixed != value { return false }
        if case .array(let allowed)? = keywords["enum"], !allowed.contains(value) { return false }
        return true
    }

    private static func stringMatches(_ value: JSONValue, _ keywords: [String: JSONValue]) -> Bool {
        guard case .string(let text) = value else { return true }
        let length = Double(text.unicodeScalars.count)
        if case .number(let least)? = keywords["minLength"], length < least { return false }
        if case .number(let most)? = keywords["maxLength"], length > most { return false }
        if case .string(let pattern)? = keywords["pattern"] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, range: range) == nil { return false }
        }
        return true
    }

    private static func numberMatches(_ value: JSONValue, _ keywords: [String: JSONValue]) -> Bool {
        guard case .number(let number) = value else { return true }
        if case .number(let least)? = keywords["minimum"], number < least { return false }
        if case .number(let above)? = keywords["exclusiveMinimum"], number <= above { return false }
        return true
    }

    private static func arrayMatches(_ value: JSONValue, _ keywords: [String: JSONValue]) -> Bool {
        guard case .array(let items) = value else { return true }
        if case .number(let least)? = keywords["minItems"], Double(items.count) < least { return false }
        if case .number(let most)? = keywords["maxItems"], Double(items.count) > most { return false }
        var first = 0
        if case .array(let prefix)? = keywords["prefixItems"] {
            for (item, schema) in zip(items, prefix) where !matches(item, schema) { return false }
            first = prefix.count
        }
        if let rest = keywords["items"] {
            for item in items.dropFirst(first) where !matches(item, rest) { return false }
        }
        return true
    }

    private static func objectMatches(_ value: JSONValue, _ keywords: [String: JSONValue]) -> Bool {
        guard case .object(let fields) = value else { return true }
        if case .array(let required)? = keywords["required"] {
            for case .string(let name) in required where fields[name] == nil { return false }
        }
        var known: [String: JSONValue] = [:]
        if case .object(let properties)? = keywords["properties"] { known = properties }
        for (name, field) in fields {
            if let schema = known[name] {
                if !matches(field, schema) { return false }
            } else if case .bool(false)? = keywords["additionalProperties"] {
                return false
            }
        }
        return true
    }

    private static func oneOfMatches(_ value: JSONValue, _ keywords: [String: JSONValue]) -> Bool {
        guard case .array(let choices)? = keywords["oneOf"] else { return true }
        return choices.filter { matches(value, $0) }.count == 1
    }
}
