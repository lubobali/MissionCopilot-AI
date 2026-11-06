import CryptoKit
import Foundation

/// An agreed action's status as the pack says it, as of the last mission.
enum AgreedActionStatus: String, Codable, Sendable {
    case completed = "Completed", ongoing = "Ongoing", notStarted = "Not started"
}

/// The agreed actions from the last mission, as the pack's section says them (#129): what a site walk
/// checks first. Read only after the import's schema check (PackSections); the pack gives no ids, so each
/// action is keyed by the SHA-256 of its text, which is what was agreed.
struct AgreedActions: Codable, Equatable, Sendable {
    struct Action: Codable, Equatable, Sendable {
        let action: String
        let responsible: String
        let deadline: String  // a day, yyyy-MM-dd
        let status: AgreedActionStatus

        var key: String { Self.key(for: action) }

        static func key(for text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        /// Late: its deadline passed before the walk's day (in the officer's own time zone), the pack did not
        /// say it was completed, and the officer has not seen it done.
        func isOverdue(on walk: Date, seen: ActionSeen?, timeZone: TimeZone = .current) -> Bool {
            guard status != .completed, seen != .done else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let day = calendar.dateComponents([.year, .month, .day], from: walk)
            let walkDay = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
            return deadline < walkDay  // both yyyy-MM-dd, so text order is date order
        }
    }

    let mission: String
    let summary: String
    let actions: [Action]

    static let path = "sections/agreed-actions.json"

    static func read(_ data: Data) throws -> AgreedActions {
        try JSONDecoder().decode(AgreedActions.self, from: data)
    }
}
