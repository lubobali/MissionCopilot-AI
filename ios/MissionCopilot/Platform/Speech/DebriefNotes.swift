import Foundation

/// One note of a debrief (#142): a decision, an action (who, what, by when) or a risk, with the exact words of
/// the transcript it came from. Written by code from a sentence that was said (#152), or by the officer.
struct DebriefNote: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable { case decision, action, risk }

    let kind: Kind
    let text: String
    /// Who will do it, as said; empty when not said.
    let who: String
    /// By when, as said ("by Friday"); never turned into a date by guessing. Empty when not said.
    let byWhen: String
    /// The exact words of the debrief the note comes from.
    let quote: String
}
