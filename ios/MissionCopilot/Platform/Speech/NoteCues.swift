import Foundation

/// Each debrief sentence labelled decision, action, risk or none by code (#152, decided A). Measured on the Mac:
/// the app's model 15 of 21 at best, these cue words 50 of 51, in any sector. The words say how people speak
/// about decisions, tasks and problems, never a mission's topic; a new language is one more word list.
enum NoteCues {
    /// One language's words: the labels an officer says first ("Action, ..."), then the cue words; each is a
    /// regular expression piece, matched on lower case.
    struct Words: Sendable {
        let spoken: [(DebriefNote.Kind, String)]
        let cues: [(DebriefNote.Kind, String)]
    }

    static let languages = [english, french]

    /// The officer's spoken label first, then a decision, an action, a risk; nil when no word says which.
    static func kind(of sentence: String) -> DebriefNote.Kind? {
        let text = AnswerText.straight(sentence).lowercased()
        for kind in DebriefNote.Kind.allCases {
            let labels = languages.flatMap { $0.spoken.filter { $0.0 == kind }.map(\.1) }
            if !labels.isEmpty, matches("^(" + labels.joined(separator: "|") + ")\\b", text) { return kind }
        }
        for kind in DebriefNote.Kind.allCases {
            let cues = languages.flatMap { $0.cues.filter { $0.0 == kind }.map(\.1) }
            if !cues.isEmpty, matches("\\b(" + cues.joined(separator: "|") + ")", text) { return kind }
        }
        return nil
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
