import Foundation

/// What a rule's computed value and threshold are counted in.
enum RuleUnit: String, Codable, Sendable { case percent, days, points, count }

/// One red-flag rule as data (ADR 0010, #134): its id and version (what a flag records), its public or
/// custom source, its title in English and French, and the threshold its computed value must go above.
struct RedFlagRule: Sendable, Equatable {
    struct Title: Sendable, Equatable {
        let english: String
        let french: String

        func text(_ language: String) -> String { language == "fr" ? french : english }
    }

    /// Every rule flags when its value is strictly above the threshold, so one test covers them all.
    struct Threshold: Codable, Sendable, Equatable {
        let value: Double
        let unit: RuleUnit

        func isCrossed(by computed: Double) -> Bool { computed > value }
    }

    let id: String
    let version: String
    let source: String
    let title: Title
    let threshold: Threshold

    var ref: RuleRef { RuleRef(id: id, version: version) }
}

/// The bundled rules file (docs/rules/red-flag-rules.json, the same file the ADR guard reads), read
/// strictly: an unknown field, unit or file version is refused rather than skipped, so a rule can never
/// run with half its meaning.
struct RedFlagRules: Sendable, Equatable {
    struct Refused: Error, Equatable { let why: String }

    static let fileVersion = 1
    static let empty = RedFlagRules(rules: [])
    let rules: [RedFlagRule]

    private init(rules: [RedFlagRule]) { self.rules = rules }

    subscript(id: String) -> RedFlagRule? { rules.first { $0.id == id } }

    static func bundled(_ bundle: Bundle = .main) throws -> RedFlagRules {
        guard let url = bundle.url(forResource: "red-flag-rules", withExtension: "json")
        else { throw Refused(why: "the rules file is not in the app") }
        return try RedFlagRules(json: Data(contentsOf: url))
    }

    init(json: Data) throws(Refused) {
        guard case .object(let root)? = try? JSONValue.parse(json) else { throw Refused(why: "not JSON") }
        try Self.only(["version", "rules"], in: root, "the file")
        guard case .number(let version)? = root["version"], Int(exactly: version) == Self.fileVersion
        else { throw Refused(why: "file version") }
        guard case .array(let items)? = root["rules"], !items.isEmpty else { throw Refused(why: "no rules") }
        rules = try items.map(Self.rule)
        guard Set(rules.map(\.id)).count == rules.count else { throw Refused(why: "a repeated id") }
    }

    private static func rule(_ item: JSONValue) throws(Refused) -> RedFlagRule {
        guard case .object(let fields) = item else { throw Refused(why: "a rule that is not an object") }
        try only(["id", "version", "source", "title", "threshold"], in: fields, "a rule")
        guard case .object(let title)? = fields["title"], case .object(let threshold)? = fields["threshold"]
        else { throw Refused(why: "a rule without title or threshold") }
        try only(["en", "fr"], in: title, "a title")
        try only(["value", "unit"], in: threshold, "a threshold")
        guard case .number(let value)? = threshold["value"], value >= 0, value.isFinite
        else { throw Refused(why: "a threshold below zero") }
        guard case .string(let unitName)? = threshold["unit"], let unit = RuleUnit(rawValue: unitName)
        else { throw Refused(why: "an unknown unit") }
        return RedFlagRule(id: try text("id", fields), version: try text("version", fields),
                           source: try text("source", fields),
                           title: .init(english: try text("en", title), french: try text("fr", title)),
                           threshold: .init(value: value, unit: unit))
    }

    private static func text(_ key: String, _ fields: [String: JSONValue]) throws(Refused) -> String {
        guard case .string(let value)? = fields[key], !value.isEmpty else { throw Refused(why: "an empty \(key)") }
        return value
    }

    private static func only(_ keys: Set<String>, in fields: [String: JSONValue], _ what: String) throws(Refused) {
        guard Set(fields.keys) == keys else { throw Refused(why: "\(what) has other fields than \(keys.sorted())") }
    }
}
