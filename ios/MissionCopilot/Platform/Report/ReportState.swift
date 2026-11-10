import Foundation

/// A report's state (#163, step 7.3.1; review-gate practice: explicit states before an approval). Approve only
/// when ready: every sentence proven, and the screen holds exactly the saved draft (its sections, words and
/// facts, in order), so what is signed is what was saved and what the officer sees.
enum ReportState: Equatable, Sendable {
    case needsProof(Int), draft, ready, approved

    static func of(lines: [ReportLine], saved: ReportDraft?, approved: Bool) -> ReportState {
        if approved { return .approved }
        let unproven = lines.filter { !$0.checked || $0.factIds.isEmpty }.count
        if unproven > 0 { return .needsProof(unproven) }
        guard let saved, !lines.isEmpty, matches(lines, saved) else { return .draft }
        return .ready
    }

    private static func matches(_ lines: [ReportLine], _ draft: ReportDraft) -> Bool {
        lines.map(\.section.rawValue) == draft.sentences.map(\.section)
            && lines.map(\.text) == draft.sentences.map(\.text)
            && lines.map(\.factIds) == draft.sentences.map(\.factIds)
    }
}
