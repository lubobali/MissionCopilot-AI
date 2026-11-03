import Foundation

/// Parsed JSON as values, so a schema check can tell true from 1 and 1 from "1" the way JSON Schema does
/// (JSONSerialization alone gives one NSNumber for a boolean and a number).
indirect enum JSONValue: Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    struct NotJSON: Error {}

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONValue(any: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(any: Any) throws {
        switch any {
        case is NSNull: self = .null
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let text as String: self = .string(text)
        case let items as [Any]: self = .array(try items.map(JSONValue.init(any:)))
        case let fields as [String: Any]: self = .object(try fields.mapValues(JSONValue.init(any:)))
        default: throw NotJSON()
        }
    }

    /// JSON Schema's type names; an integer is any number with no fractional part.
    func isType(_ name: String) -> Bool {
        switch (name, self) {
        case ("null", .null), ("boolean", .bool), ("number", .number), ("string", .string), ("array", .array),
             ("object", .object): true
        case ("integer", .number(let value)): value.rounded() == value && value.isFinite
        default: false
        }
    }
}
