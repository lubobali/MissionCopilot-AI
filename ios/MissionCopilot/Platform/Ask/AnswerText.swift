import Foundation

/// The words of a sentence the checks read (#145, found on the iPhone).
enum AnswerText {
    /// Curly quotes and apostrophes as straight ones: iOS Smart Punctuation types ’ for ', and pasted text can
    /// bring “ ” (found on the iPhone: "What’s done?" missed its answer).
    static func straight(_ text: String) -> String {
        text.replacingOccurrences(of: "[\u{2018}\u{2019}\u{201B}\u{2032}]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[\u{201C}\u{201D}\u{201F}\u{2033}]", with: "\"", options: .regularExpression)
    }

    /// A sentence that only says the sources do not answer ("not specified in the provided sources").
    static func saysNotAnswered(_ text: String) -> Bool {
        straight(text).range(of: notAnsweredPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let notAnsweredPattern = #"\bnot (specified|mentioned|provided|stated|given|available|found|"#
        + #"included|listed|indicated|clear)\b|\bno (information|data|mention|record)\b|"#
        + #"\b(does|do|did) not (say|mention|specify|include|contain|state|provide|indicate)\b|"#
        + #"\bcannot be (determined|found|answered)\b|\bn'est pas (précisé|indiqué|mentionné)|"#
        + #"\baucune (information|donnée|mention)\b|\bne (précise|mentionne|indique) pas\b"#
}
