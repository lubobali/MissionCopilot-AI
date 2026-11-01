import Foundation

/// Turns a script or a transcript into comparable words, the same way for both (English and French):
/// lowercase, one apostrophe, numbers without thousands separators and with a decimal point, and one
/// spelling per unit. Numbers written as words stay words: code downstream needs digits.
public enum Normalizer {
    static let units: [String: String] = [
        "metre": "m", "metres": "m", "meter": "m", "meters": "m", "mètre": "m", "mètres": "m",
        "kilometre": "km", "kilometres": "km", "kilometer": "km", "kilometers": "km",
        "kilomètre": "km", "kilomètres": "km", "millions": "million",
    ]

    public static func words(_ text: String, language: String) -> [String] {
        var text = text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        // "480 000" (French, also with no-break spaces) and "480,000" (English) -> "480000".
        text = repeatedly(#"(\d)[ \u00A0\u202F](\d{3})(?!\d)"#, "$1$2", in: text)
        text = repeatedly(#"(\d),(\d{3})(?!\d)"#, "$1$2", in: text)
        text = replace(#"(\d),(\d)"#, "$1.$2", in: text)  // French decimal comma: "4,9" -> "4.9"
        text = replace(#"(\d)\s*%"#, "$1 percent", in: text)
        text = replace(#"\b(pour|per) cent\b"#, "percent", in: text)
        let kept = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
                || scalar == "'" || scalar == "." ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").compactMap { token in
            let word = token.trimmingCharacters(in: CharacterSet(charactersIn: ".'"))
            return word.isEmpty ? nil : units[word] ?? word
        }
    }

    static func replace(_ pattern: String, _ template: String, in text: String) -> String {
        // A bad pattern must fail loudly: an invalid regex silently changing nothing hid a bug here once.
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("invalid pattern: \(pattern)")
        }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: template)
    }

    /// Applied until nothing changes: "8,500,000" needs two passes.
    static func repeatedly(_ pattern: String, _ template: String, in text: String) -> String {
        var current = text
        while true {
            let next = replace(pattern, template, in: current)
            if next == current { return current }
            current = next
        }
    }
}

/// Word error rate: (substitutions + deletions + insertions) / reference words, by word-level edit distance.
public enum WordErrorRate {
    public struct Result: Sendable, Equatable {
        public let substitutions: Int
        public let deletions: Int
        public let insertions: Int
        public let referenceCount: Int

        public var rate: Double {
            referenceCount == 0 ? 0 : Double(substitutions + deletions + insertions) / Double(referenceCount)
        }
    }

    public static func compute(reference: [String], hypothesis: [String]) -> Result {
        // cost[i][j] = (total, substitutions, deletions, insertions) for reference[..<i] vs hypothesis[..<j]
        typealias Cell = (total: Int, sub: Int, del: Int, ins: Int)
        var previous: [Cell] = (0...hypothesis.count).map { ($0, 0, 0, $0) }
        for i in 1...max(reference.count, 1) where !reference.isEmpty {
            var current: [Cell] = [(i, 0, i, 0)]
            for j in 1...max(hypothesis.count, 1) where !hypothesis.isEmpty {
                let diagonal = previous[j - 1]
                let same = reference[i - 1] == hypothesis[j - 1]
                let options: [Cell] = [
                    (diagonal.total + (same ? 0 : 1), diagonal.sub + (same ? 0 : 1), diagonal.del, diagonal.ins),
                    (previous[j].total + 1, previous[j].sub, previous[j].del + 1, previous[j].ins),
                    (current[j - 1].total + 1, current[j - 1].sub, current[j - 1].del, current[j - 1].ins + 1),
                ]
                current.append(options.min { $0.total < $1.total } ?? options[0])
            }
            previous = current
        }
        let last = reference.isEmpty ? (hypothesis.count, 0, 0, hypothesis.count)
            : (hypothesis.isEmpty ? (reference.count, 0, reference.count, 0) : previous[hypothesis.count])
        return Result(substitutions: last.1, deletions: last.2, insertions: last.3, referenceCount: reference.count)
    }
}

/// One key fact and how it is spoken in one language (from the answer key).
public struct SpokenFact: Codable, Sendable, Equatable {
    public let name: String
    public let value: String
    public let spoken: String

    public init(name: String, value: String, spoken: String) {
        self.name = name
        self.value = value
        self.spoken = spoken
    }
}

/// Each key fact must appear in the transcript, in digits, as consecutive normalized words.
public enum FactScore {
    public struct Result: Sendable, Equatable {
        public let found: [String]
        public let missing: [String]
    }

    public static func score(_ facts: [SpokenFact], in transcript: String, language: String) -> Result {
        let words = Normalizer.words(transcript, language: language)
        var found: [String] = []
        var missing: [String] = []
        for fact in facts {
            let needle = Normalizer.words(fact.spoken, language: language)
            if contains(words, needle) { found.append(fact.name) } else { missing.append(fact.name) }
        }
        return Result(found: found, missing: missing)
    }

    static func contains(_ words: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= words.count else { return false }
        return (0...(words.count - needle.count)).contains { Array(words[$0..<$0 + needle.count]) == needle }
    }
}
