import Foundation

/// The words of a sentence the checks read (#145, found on the iPhone).
enum AnswerText {
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
