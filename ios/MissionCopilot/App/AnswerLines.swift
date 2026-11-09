import Foundation

/// One answer line written by code from the mission's records, with the ids of the records it cites.
struct CodeLine: Codable, Equatable, Sendable {
    let text: String
    let sources: [String]
}

/// The language an answer is written in: the question's, English or French.
enum AnswerLanguage: Equatable, Sendable {
    case english, french

    init(question: String) {
        self = AskRecord.language(of: question) == "fr" ? .french : .english
    }

    func pick(_ english: String, _ french: String) -> String { self == .french ? french : english }
}

/// Answer lines written by code (#145, step 6.7.11). Found on the iPhone: the 1.2B model writes answers badly,
/// so the app writes every answer itself from the records, short and plain ("Invoice 14: USD 480,000, paid
/// 12 Oct 2026."). Payments, the total, agreed actions, milestones, the walk, red flags, scans and debrief
/// notes have their own words; any other pack record reads "Title: field; field", whatever the sector.
enum AnswerLines {
    static func line(_ source: MissionSource, question: String = "", language: AnswerLanguage = .english) -> CodeLine {
        CodeLine(text: text(source, question: question, language: language), sources: [source.id])
    }

    private static func text(_ source: MissionSource, question: String, language: AnswerLanguage) -> String {
        let card = SourceWords.card(source)
        switch source.origin {
        case .pack: return pack(source, card: card, language: language)
        case .document(let path, _):
            let quote = bestSentence(source.text, card: card, question: question)
            return "\(SourceWords.documentName(path)): " + language.pick("\"\(quote)\"", "« \(quote) »")
        case .walk:
            if source.title.hasPrefix(checkPrefix) {
                let seen = card.lines.first.map(plain).map { $0.replacingOccurrences(of: ":", with: "") } ?? ""
                let action = String(source.title.dropFirst(checkPrefix.count))
                return language.pick("Your site walk: ", "Votre visite : ") + "\(action), \(seen)."
            }
            return language.pick("Your site walk: ", "Votre visite : ") + "\(source.title) \(card.lines.first ?? "")."
        case .fact:
            let line = card.lines.first ?? source.text
            if source.kind == .note {
                return language.pick("From your debrief: ", "Selon votre compte rendu : ") + line
            }
            if source.title.hasPrefix(MissionSources.typedTitle) {
                return language.pick("You typed this, it is not on the scanned page: ",
                                     "Vous l'avez saisi, ce n'est pas sur la page scannée : ") + "\(line)."
            }
            if source.title.hasPrefix("Heard") {
                return language.pick("Heard in your debrief: ", "Entendu dans votre compte rendu : ") + "\(line)."
            }
            return language.pick("From your scanned invoice: ", "Selon votre facture scannée : ") + "\(line)."
        case .redFlag(let rule):
            return language.pick("Red flag \(rule): ", "Signal \(rule) : ") + source.text
        }
    }

    private static let checkPrefix = "Agreed action: "

    private static func pack(_ source: MissionSource, card: SourceCardWords, language: AnswerLanguage) -> String {
        let colon = language.pick(":", " :")
        let field = { (name: String) in
            card.lines.first { $0.hasPrefix(name + ": ") }.map { String($0.dropFirst(name.count + 2)) }
        }
        let name = card.title.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
        if source.id.hasSuffix("#paid"), let raw = source.text.firstMatch(of: /^(\d+)/) {
            let total = SourceWords.value(String(raw.1), key: "amount")
            let count = source.text.firstMatch(of: /(\d+) payments/).map { String($0.1) } ?? ""
            return language.pick("\(total) paid to date (the sum of \(count) payments).",
                                 "\(total) payés à ce jour (somme de \(count) paiements).")
        }
        if card.title.hasPrefix("Payment · "), let amount = field("Amount"), let date = field("Date") {
            return "\(name)\(colon) \(amount), " + language.pick("paid \(date).", "payée le \(date).")
        }
        if card.title.hasPrefix("Contract · "), let value = field("Contract value") {
            let supplier = field("Supplier").map { language.pick(", supplier \($0)", ", fournisseur \($0)") } ?? ""
            let status = field("Status").map { ", \(statusWords($0, language))" } ?? ""
            return "\(name)\(colon) \(value)\(supplier)\(status)."
        }
        if card.title.hasPrefix("Agreed action · "), let status = field("Status") {
            let deadline = field("Deadline").map { language.pick(", deadline \($0)", ", échéance \($0)") } ?? ""
            let who = field("Responsible").map { ", \($0)" } ?? ""
            return "\(name)\(colon) \(statusWords(status, language))\(deadline)\(who)."
        }
        if card.title.hasPrefix("Milestone · "), let status = field("Status") {
            if let met = field("Date met") {
                return "\(name)\(colon) " + language.pick("met \(met).", "atteint le \(met).")
            }
            let due = field("Due date").map { language.pick(", due \($0)", ", prévu le \($0)") } ?? ""
            return "\(name)\(colon) \(statusWords(status, language))\(due)."
        }
        // #161, 7.2.7 (found on the iPhone): any rating and any physical progress, in plain words.
        if let now = field("Current"), let before = field("Previous") {
            return "\(name)\(colon) \(now) " + language.pick("(\(before) before).", "(avant : \(before)).")
        }
        if let built = field("Km built"), let total = field("Km total"), let unit = field("Unit"),
           let asOf = field("As of") {
            return "\(name)\(colon) " + language.pick("\(built) of \(total) \(unit) built, as of \(asOf).",
                                                     "\(built) sur \(total) \(unit) réalisés, au \(asOf).")
        }
        return "\(card.title)\(colon) \(card.lines.prefix(4).joined(separator: "; "))."
    }

    /// "Not started", "notMet" in plain words, in the answer's language.
    static func statusWords(_ raw: String, _ language: AnswerLanguage) -> String {
        let words = plain(raw)
        guard language == .french else { return words }
        let french = ["not started": "pas commencé", "ongoing": "en cours", "completed": "terminé", "met": "atteint",
                      "not met": "pas atteint", "scheduled": "prévu", "partially met": "en partie atteint"]
        return french[words] ?? words
    }

    /// "notMet" as "not met", "Not started" as "not started", "Seen: done." as "seen: done".
    private static func plain(_ raw: String) -> String {
        var out = ""
        for character in raw.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) {
            if character.isUppercase, !out.isEmpty { out += " " }
            out += character == "_" ? " " : character.lowercased()
        }
        return out
    }

    /// The sentence (or table row) of a paragraph that shares the most words with the question, as written.
    private static func bestSentence(_ text: String, card: SourceCardWords, question: String) -> String {
        let pieces = card.lines.count > 1 ? card.lines
            : text.components(separatedBy: ". ").map { $0.hasSuffix(".") ? $0 : $0 + "." }
        let asked = Set(MissionSearch.terms(question).flatMap { [$0] + (MissionSearch.related[$0] ?? []) })
        let best = pieces.enumerated().max { first, second in
            let (one, two) = (overlap(first.element, asked), overlap(second.element, asked))
            return one == two ? first.offset > second.offset : one < two
        }
        return (best?.element ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func overlap(_ piece: String, _ asked: Set<String>) -> Int {
        Set(MissionSearch.terms(piece)).intersection(asked).count
    }
}
