import Foundation

/// A source found for a question, with its score (higher is closer).
struct SearchHit: Equatable, Sendable {
    let source: MissionSource
    let score: Double
}

/// Keyword search over the mission's sources (#145, step 6.7.2): BM25, offline, the same result every time.
/// Checked on the web: Apple's sentence embeddings need a model download on request and publish no accuracy,
/// while our sources are short and full of names and numbers, where keywords do well.
struct MissionSearch: Sendable {
    private struct Entry: Sendable {
        let source: MissionSource
        let counts: [String: Int]
        let length: Int
    }

    /// Every source searched, in order.
    let sources: [MissionSource]
    private let entries: [Entry]
    private let frequency: [String: Int]
    private let averageLength: Double

    init(sources: [MissionSource]) {
        self.sources = sources
        entries = sources.map { source in
            let terms = Self.terms(AnswerCheck.evidenceText(source))
            return Entry(source: source, counts: terms.reduce(into: [:]) { $0[$1, default: 0] += 1 },
                         length: terms.count)
        }
        frequency = entries.reduce(into: [:]) { all, entry in entry.counts.keys.forEach { all[$0, default: 0] += 1 } }
        averageLength = entries.isEmpty ? 1 : Double(entries.map(\.length).reduce(0, +)) / Double(entries.count)
    }

    /// The best sources for a question, best first: at most `limit`, and no more text than `budget` characters
    /// in all (what the model will read). A question with no word the mission knows finds nothing. A follow-up
    /// also searches with the officer's earlier questions in the chat (#145, 6.7.4), each word counted half,
    /// so "And when was it paid?" finds the invoice asked about before, while the new question still leads.
    func search(_ question: String, earlier: [String] = [], limit: Int = 5, budget: Int = 6_000) -> [SearchHit] {
        var weights: [String: Double] = [:]
        for text in earlier.suffix(Self.earlierKept) {
            for term in Self.expanded(text) { weights[term] = max(weights[term] ?? 0, Self.earlierWeight) }
        }
        // The new question must itself match something: earlier questions only help to rank.
        let own = Self.expanded(question)
        guard own.contains(where: { frequency[$0] != nil }) else { return [] }
        for term in own { weights[term] = 1 }
        let order = weights.keys.sorted()
        // BM25 with its usual settings: how fast repeats stop counting (1.2), and how much a long source weighs (0.75).
        let (saturation, lengthWeight, count) = (1.2, 0.75, Double(entries.count))
        let ranked = entries.compactMap { entry -> SearchHit? in
            // Summed in a fixed order, so the same question always gives the same scores to the last digit.
            let score = order.reduce(0.0) { total, term in
                let weight = weights[term] ?? 0
                guard let times = entry.counts[term].map(Double.init), let holding = frequency[term].map(Double.init)
                else { return total }
                let rarity = log((count - holding + 0.5) / (holding + 0.5) + 1)
                let length = 1 - lengthWeight + lengthWeight * Double(entry.length) / averageLength
                return total + weight * rarity * times * (saturation + 1) / (times + saturation * length)
            }
            return score > 0 ? SearchHit(source: entry.source, score: score) : nil
        }.sorted { ($0.score, $1.source.id) > ($1.score, $0.source.id) }
        var hits: [SearchHit] = [], used = 0
        for hit in ranked where hits.count < limit && used + hit.source.text.count <= budget {
            hits.append(hit)
            used += hit.source.text.count
        }
        return hits
    }
}

extension MissionSearch {
    /// How many earlier questions a follow-up uses, and how much each of their words counts.
    static let earlierKept = 3
    static let earlierWeight = 0.5

    /// A text's terms with their mission synonyms and French glossary words.
    static func expanded(_ text: String) -> Set<String> {
        Set(terms(text).flatMap { [$0] + (related[$0] ?? []) })
    }

    /// Text as search terms: lower case, letters and digits only, a letter next to a digit is two words,
    /// "480,000" is one number, number words are digits, common words dropped, word endings trimmed.
    static func terms(_ text: String) -> [String] {
        let joined = text.lowercased().replacingOccurrences(of: #"(?<=\d),(?=\d{3})"#, with: "",
                                                             options: .regularExpression)
        var words: [String] = [], current = ""
        for character in joined + " " {
            let isWord = character.isLetter || character.isNumber
            if isWord, let last = current.last, last.isNumber != character.isNumber {
                words.append(current)
                current = ""
            }
            if isWord { current.append(character) } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        return words.compactMap { word in
            if let number = NumberWords.small[word] ?? NumberWords.tens[word] { return String(Int(number)) }
            return stopWords.contains(word) ? nil : stem(word)
        }
    }

    /// A light trim of English and French endings, so "started" finds "start" and "payée" finds "pay".
    static func stem(_ word: String) -> String {
        guard !word.allSatisfy(\.isNumber) else { return word }
        for ending in ["ing", "ées", "és", "ée", "ed", "es", "é", "s", "e"] where word.hasSuffix(ending)
            && word.count - ending.count >= 3 {
            return String(word.dropLast(ending.count))
        }
        return word
    }

    static let stopWords: Set = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "has", "have", "had", "do", "does", "did", "of",
        "to", "in", "on", "at", "for", "by", "with", "and", "or", "what", "when", "how", "much", "many", "who",
        "which", "there", "this", "that", "it", "its", "from", "as", "so", "far", "any", "will", "can", "into",
        "le", "la", "les", "l", "de", "du", "des", "un", "une", "et", "est", "t", "il", "elle", "elles", "ils",
        "en", "au", "aux", "que", "qui", "quel", "quelle", "quand", "été", "se", "ce", "d", "pour", "par", "sur",
        "dans", "combien", "y"
    ]

    /// Mission words that mean the same, and French words to the English the sources use (terms after `stem`).
    static let related: [String: [String]] = [
        "paid": ["payment", "disburs", "amount"], "pay": ["payment", "disburs", "amount", "paid"],
        "payment": ["disburs", "amount"], "contractor": ["supplier"], "late": ["delay"], "why": ["reason"],
        "promis": ["committ", "agre"], "built": ["complet"], "end": ["clos"],
        "pont": ["bridg"], "commenc": ["start"], "factur": ["invoic"], "montant": ["valu", "amount"],
        "contrat": ["contract"], "pourquoi": ["reason", "delay"], "entrepris": ["contractor", "supplier"],
        "retard": ["delay", "late"], "rout": ["road"], "kilomètr": ["km"], "risqu": ["risk"],
        "plaint": ["grievanc"], "achev": ["complet"],
        "factura": ["invoic"], "délai": ["deadlin", "delay"], "promess": ["committ"]
    ]
}
