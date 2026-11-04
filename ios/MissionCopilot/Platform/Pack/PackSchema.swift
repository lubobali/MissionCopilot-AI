import Foundation

/// The phone's check of a pack file against the pack sections schema (#92): the very file the server's
/// tests use, bundled into the app, read for exactly the JSON Schema 2020-12 keywords that schema uses. A
/// schema with any other keyword is refused when it loads, so a new rule there can never be skipped here
/// in silence. The shared cases (docs/api/fixtures/pack-section-cases.json) hold it to the reference
/// validator's answers: never laxer, never stricter.
struct PackSchema: Sendable {
    enum Problem: Error, Equatable { case notFound, unreadable, unsupported(String) }

    static let checks: Set<String> = [
        "type", "required", "properties", "additionalProperties", "enum", "const", "pattern", "minLength",
        "maxLength", "minimum", "exclusiveMinimum", "items", "prefixItems", "minItems", "maxItems", "oneOf"
    ]
    static let notes: Set<String> = ["$schema", "$id", "$defs", "$comment", "title", "description"]

    let definitions: [String: JSONValue]

    init(json: Data) throws(Problem) {
        guard case .object(let root)? = try? JSONValue.parse(json), case .object(let defs)? = root["$defs"]
        else { throw .unreadable }
        try Self.supported(.object(root))
        definitions = defs
    }

    static func bundled(_ bundle: Bundle = .main) throws(Problem) -> PackSchema {
        guard let url = bundle.url(forResource: "pack-sections.schema", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { throw .notFound }
        return try PackSchema(json: data)
    }

    /// Whether `value` matches the definition `name` (a section's or form's file name without ".json").
    func isValid(_ value: JSONValue, as name: String) -> Bool {
        guard let schema = definitions[name] else { return false }
        return Self.matches(value, schema)
    }

    private static func supported(_ schema: JSONValue) throws(Problem) {
        guard case .object(let keywords) = schema else {
            if case .bool = schema { return }
            throw .unsupported("a schema that is not an object")
        }
        for (key, value) in keywords {
            guard checks.contains(key) || notes.contains(key) else { throw .unsupported(key) }
            for child in try children(key, value) { try supported(child) }
        }
    }

    /// The schemas inside one keyword, to be checked in turn.
    private static func children(_ key: String, _ value: JSONValue) throws(Problem) -> [JSONValue] {
        switch (key, value) {
        case ("properties", .object(let all)), ("$defs", .object(let all)): Array(all.values)
        case ("prefixItems", .array(let all)), ("oneOf", .array(let all)): all
        case ("items", _): [value]
        case ("additionalProperties", .bool): []
        case ("additionalProperties", _): throw .unsupported("additionalProperties with a schema")
        default: []
        }
    }
}
