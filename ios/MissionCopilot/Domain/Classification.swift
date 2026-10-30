/// How sensitive a piece of mission data is (docs/data-classification.md).
/// Raw values match the API contract (docs/api/openapi.yaml).
enum Classification: String, Codable, Sendable, CaseIterable {
    case strictlyConfidential = "strictly_confidential"
    case officialUseOnly = "official_use_only"
    case `public` = "public"

    var isPublic: Bool { self == .public }

    /// Lower number = stricter.
    private var strictness: Int {
        switch self {
        case .strictlyConfidential: 0
        case .officialUseOnly: 1
        case .public: 2
        }
    }

    /// A derived item inherits the strictest label of its sources.
    /// With no sources, it is Official Use Only (secure by default).
    static func strictest(_ labels: [Classification]) -> Classification {
        labels.min { $0.strictness < $1.strictness } ?? .officialUseOnly
    }
}

/// One note captured in the field (typed, dictated, or extracted from a document).
struct FieldNote: Codable, Sendable {
    let text: String
    var classification: Classification = .officialUseOnly
}
