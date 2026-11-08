import Foundation

/// Where words sit in a transcript: their position and length, counted in characters.
struct TextSpan: Codable, Sendable, Equatable {
    let offset: Int
    let length: Int
}

/// A drafted note after grounding: where its quote is in the transcript (nil when not there) and its problems.
struct NoteCheck: Sendable, Equatable {
    let note: DebriefNote
    let found: TextSpan?
    let problems: [String]
}

/// Grounding a debrief's notes (#142, step 6.6.6). Pure code, no model: the quote must be words that were said,
/// who and by-when must be words of the quote, and no number or month may appear that was never said.
enum NoteGrounding {
    static func check(_ notes: [DebriefNote], transcript: String) -> [NoteCheck] {
        let spoken = Words(transcript)
        return notes.map { note in
            // Found on the iPhone: the model copied a "Debrief:" label into a quote.
            var quote = Words(note.quote).text
            if quote.hasPrefix("debrief ") { quote = String(quote.dropFirst("debrief ".count)) }
            var problems: [String] = []
            var found: TextSpan?
            if quote.isEmpty {
                problems.append("No words from the debrief were given for this note.")
            } else if let span = spoken.find(quote) {
                found = span
            } else {
                problems.append("These words are not in the debrief: “\(note.quote)”.")
            }
            // Who and by-when must be words of the quote; what the model added is left out (found on the iPhone:
            // "Immediate", "Ongoing", "Finance Team" were never said).
            let said = { (part: String) -> Bool in
                Words(part).text.isEmpty || " \(quote) ".contains(" \(Words(part).text) ")
            }
            for part in [note.who, note.byWhen] where !said(part) {
                problems.append("“\(part)” was not said here, so it is left out.")
            }
            let written = Words([note.text, note.who, note.byWhen].joined(separator: " "))
            problems += written.numbers.filter { !spoken.numbers.contains($0) }
                .map { "The number \($0) was not said in the debrief." }
            problems += written.months.filter { !spoken.months.contains($0) }
                .map { "The month \($0) was not said in the debrief." }
            if found != nil { problems += matching(note, quote: Words(quote), spoken: spoken) }
            let kept = DebriefNote(kind: note.kind, text: note.text, who: said(note.who) ? note.who : "",
                                   byWhen: said(note.byWhen) ? note.byWhen : "", quote: note.quote)
            return NoteCheck(note: kept, found: found, problems: problems)
        }
    }
}

extension NoteGrounding {
    /// Found on the iPhone: a note said "Section 5 bridges is still not started" but quoted "Invoice 36 for
    /// $360,000". The quote was said, yet it does not back the note: its numbers must be in the quote, and at
    /// least half of its main words (four letters or more, compared by their first five letters).
    fileprivate static func matching(_ note: DebriefNote, quote: Words, spoken: Words) -> [String] {
        let text = Words(note.text)
        var problems = text.numbers.filter { spoken.numbers.contains($0) && !quote.numbers.contains($0) }
            .map { "The number \($0) is not in the words quoted." }
        let stem = { (word: String) in String(word.prefix(5)) }
        let quoted = Set(quote.text.split(separator: " ").map { stem(String($0)) })
        let main = text.text.split(separator: " ").map(String.init)
            .filter { $0.count >= 4 && !$0.allSatisfy(\.isNumber) && !commonWords.contains($0) }
            .filter { Words.monthNames[$0] == nil }  // months have their own check above
        if main.count >= 2, Double(main.filter { quoted.contains(stem($0)) }.count) < Double(main.count) / 2 {
            problems.append("This note does not match the words quoted.")
        }
        return problems
    }

    private static let commonWords: Set = ["that", "this", "with", "will", "have", "from", "they", "were", "been",
                                           "their", "there", "would", "should", "about", "pour", "dans", "avec"]
}

/// Text as plain words: lower case, letters and digits only, one space between words; each character remembers
/// where it was in the original, so a match points back into the transcript.
private struct Words {
    let text: String
    private let characters: [Character]
    private let origin: [Int]

    init(_ original: String) {
        var characters: [Character] = [], origin: [Int] = []
        for (offset, character) in original.enumerated() {
            if character.isLetter || character.isNumber {
                // A letter next to a digit is two words: the model writes "March15th" for "March 15th".
                if let last = characters.last, last != " ", last.isNumber != character.isNumber {
                    characters.append(" ")
                    origin.append(offset)
                }
                characters.append(contentsOf: character.lowercased())
                origin.append(contentsOf: Array(repeating: offset, count: character.lowercased().count))
            } else if characters.last.map({ $0 != " " }) ?? false {
                characters.append(" ")
                origin.append(offset)
            }
        }
        while characters.last == " " {
            characters.removeLast()
            origin.removeLast()
        }
        (self.characters, self.origin, self.text) = (characters, origin, String(characters))
    }

    /// The original position of `words` (already plain), whole words only; a number word and its digits are
    /// the same word ("two" and "2": the engine writes digits, the model may write words).
    func find(_ words: String) -> TextSpan? {
        let needle = words.split(separator: " ").map { Self.canonical(String($0)) }
        let spans = wordSpans
        guard !needle.isEmpty, needle.count <= spans.count else { return nil }
        for start in 0...(spans.count - needle.count)
        where spans[start..<start + needle.count].map(\.word) == needle {
            let first = origin[spans[start].from], last = origin[spans[start + needle.count - 1].end - 1]
            return TextSpan(offset: first, length: last - first + 1)
        }
        return nil
    }

    /// Each plain word with where its characters are.
    private struct WordSpan {
        let word: String
        let from: Int
        let end: Int
    }

    private var wordSpans: [WordSpan] {
        var spans: [WordSpan] = []
        var from = 0
        let space: Character = " "
        for (index, character) in characters.enumerated() + [(characters.count, space)] where character == space {
            if index > from {
                spans.append(WordSpan(word: Self.canonical(String(characters[from..<index])), from: from, end: index))
            }
            from = index + 1
        }
        return spans
    }

    /// A small number word as its digits; any other word as it is.
    static func canonical(_ word: String) -> String {
        numberWords[word].map(String.init) ?? word
    }

    private var tokens: [String] { text.split(separator: " ").map(String.init) }

    /// Every number, from digits ("480000", "15") or a small number word ("two", "deux"), in order, each once.
    var numbers: [String] {
        var seen: [String] = []
        for token in tokens {
            let number = token.allSatisfy(\.isNumber) ? String(Int(token) ?? 0)
                : Self.numberWords[token].map(String.init)
            if let number, !seen.contains(number) { seen.append(number) }
        }
        return seen
    }

    /// Every month named, in English or French, as its English name; "may" only next to a number (it is also
    /// a common word).
    var months: [String] {
        let tokens = tokens
        var seen: [String] = []
        for (index, token) in tokens.enumerated() {
            guard let month = Self.monthNames[token] else { continue }
            if token == "may" {
                let near = [index - 1, index + 1].filter(tokens.indices.contains).map { tokens[$0] }
                guard near.contains(where: { $0.allSatisfy(\.isNumber) }) else { continue }
            }
            if !seen.contains(month) { seen.append(month) }
        }
        return seen
    }

    static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30,
        "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "sept": 7, "huit": 8, "neuf": 9,
        "dix": 10, "onze": 11, "douze": 12, "quinze": 15, "vingt": 20, "trente": 30
    ]

    static let monthNames: [String: String] = {
        let english = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                       "october", "november", "december"]
        let french = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre",
                      "octobre", "novembre", "décembre"]
        var names: [String: String] = [:]
        for (index, month) in english.enumerated() {
            let name = month.prefix(1).uppercased() + month.dropFirst()
            names[month] = name
            names[String(month.prefix(3))] = name
            names[french[index]] = name
        }
        names["sept"] = nil  // "sept" is French for seven
        names["fevrier"] = "February"
        names["aout"] = "August"
        names["decembre"] = "December"
        return names
    }()
}
