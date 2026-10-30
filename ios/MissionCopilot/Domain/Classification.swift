/// How sensitive a piece of mission data is. Secure by default: anything new is
/// Official Use Only until a person decides otherwise.
enum Classification: String, Codable, Sendable {
    case officialUseOnly
    case `public`

    var isPublic: Bool { self == .public }
}

/// One note captured in the field (typed, dictated, or extracted from a document).
struct FieldNote: Codable, Sendable {
    let text: String
    var classification: Classification = .officialUseOnly
}
