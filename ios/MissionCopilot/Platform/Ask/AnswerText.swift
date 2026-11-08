import Foundation

/// The words of a model's sentence before the checks (#145, found on the iPhone).
enum AnswerText {
    /// "Section3" as "Section 3", "July2026" as "July 2026": the engine pushes lone space tokens down (spike
    /// #13), so a space before or after a number is sometimes lost. A word of two letters or more next to a
    /// number is spaced again; ordinals ("12th", "1er") and short ids ("P1", "MC-02") stay as they are.
    static func respaced(_ text: String) -> String {
        let afterWord = text.replacingOccurrences(of: #"(?<=\p{L}{2})(?=\d)"#, with: " ", options: .regularExpression)
        return afterWord.replacingOccurrences(of: #"(?<=\d)(?!(?:st|nd|rd|th|er|e|re|ème)\b)(?=\p{L}{2})"#,
                                              with: " ", options: [.regularExpression, .caseInsensitive])
    }

    /// A sentence that only says the sources do not answer ("not specified in the provided sources").
    static func saysNotAnswered(_ text: String) -> Bool {
        text.range(of: notAnsweredPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let notAnsweredPattern = #"\bnot (specified|mentioned|provided|stated|given|available|found|"#
        + #"included|listed|indicated|clear)\b|\bno (information|data|mention|record)\b|"#
        + #"\b(does|do|did) not (say|mention|specify|include|contain|state|provide|indicate)\b|"#
        + #"\bcannot be (determined|found|answered)\b|\bn'est pas (précisé|indiqué|mentionné)|"#
        + #"\baucune (information|donnée|mention)\b|\bne (précise|mentionne|indique) pas\b"#
}
