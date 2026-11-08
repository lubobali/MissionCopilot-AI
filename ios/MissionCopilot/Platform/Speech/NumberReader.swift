import Foundation

/// Reads the numbers of one transcript, word by word, keeping where each word was (#142, step 6.6.7).
struct NumberReader {
    private struct Token {
        let text: String  // as written, without trailing punctuation
        let word: String  // lower case
        let start: Int
        let end: Int
    }

    private let transcript: String
    private let tokens: [Token]

    init(_ transcript: String) {
        self.transcript = transcript
        var tokens: [Token] = []
        var start: Int?
        var current = ""
        // Every character, then one more space so the last word ends (plain for CI's older compiler).
        let characters: [Character] = Array(transcript) + [" "]
        for offset in characters.indices {
            let character = characters[offset]
            if character.isWhitespace {
                if let begin = start {
                    let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"“”()"))
                    let lead = current.prefix { ",.;:!?\"“”(".contains($0) }.count
                    if !trimmed.isEmpty {
                        tokens.append(Token(text: trimmed, word: trimmed.lowercased(), start: begin + lead,
                                            end: begin + lead + trimmed.count))
                    }
                }
                (start, current) = (nil, "")
            } else {
                if start == nil { start = offset }
                current.append(character)
            }
        }
        self.tokens = tokens
    }

    func read() -> [HeardNumber] {
        var heard: [HeardNumber] = []
        var index = 0
        while index < tokens.count {
            if let (number, next) = date(at: index) ?? number(at: index) {
                heard.append(number)
                index = next
            } else {
                index += 1
            }
        }
        return heard
    }

    // MARK: dates

    private func date(at index: Int) -> (HeardNumber, Int)? {
        let token = tokens[index]
        if Self.weekdays.contains(token.word) { return (make(index, index, value: token.text, kind: .date), index + 1) }
        if NumberWords.month(token.word) != nil, index + 1 < tokens.count, let day = Self.day(tokens[index + 1].word),
           (1...31).contains(day) {
            return (make(index, index + 1, value: "\(token.text) \(day)", kind: .date), index + 2)
        }
        if let day = Self.day(token.word), (1...31).contains(day), index + 1 < tokens.count,
           NumberWords.month(tokens[index + 1].word) != nil {
            return (make(index, index + 1, value: "\(day) \(tokens[index + 1].text)", kind: .date), index + 2)
        }
        return nil
    }

    // MARK: numbers

    private func number(at index: Int) -> (HeardNumber, Int)? {
        guard var (value, last) = digits(at: index) ?? words(at: index) else { return nil }
        if last + 1 < tokens.count, let scale = NumberWords.scales[tokens[last + 1].word], scale >= 1_000 {
            value *= scale
            last += 1
        }
        var unitIndex: Int? = last + 1 < tokens.count && Self.units[tokens[last + 1].word] != nil ? last + 1 : nil
        if unitIndex == nil, last + 2 < tokens.count, tokens[last + 1].word == "pour", tokens[last + 2].word == "cent" {
            unitIndex = last + 2
        }
        let dollarSign = tokens[index].word.hasPrefix("$")
        let unit = unitIndex.map { tokens[$0].text } ?? (dollarSign ? "dollars" : nil)
        if last == index, value == 1, unit == nil, ["un", "une", "one"].contains(tokens[index].word) { return nil }
        let kind = unitIndex.flatMap { Self.units[tokens[$0].word] }
            ?? (dollarSign ? .amount : tokens[index].word.hasSuffix("%") ? .percent : value >= 1_000 ? .amount : .count)
        var heard = make(index, last, value: Self.format(value), kind: kind, unit: unit)
        let before = tokens[max(0, index - 3)..<index].map(\.word)
        // An amount said without "dollars" still counts when it follows an invoice ("invoice 22 for 5,000").
        if let invoice = invoiceBefore(index), kind == .amount || (kind == .count && value >= 100) {
            heard.invoice = invoice
            heard.kind = .amount
        }
        heard.paid = heard.kind == .amount && before.contains { ["paid", "payé", "payés", "payée"].contains($0) }
        return (heard, (unitIndex ?? last) + 1)
    }

    /// The invoice number said just before this amount ("invoice 14 for 480,000").
    private func invoiceBefore(_ index: Int) -> String? {
        for back in stride(from: index - 1, through: max(0, index - 4), by: -1) where back > 0 {
            if ["invoice", "facture"].contains(tokens[back - 1].word),
               let (number, last) = digits(at: back) ?? words(at: back), last < index {
                return Self.format(number)
            }
        }
        return nil
    }

    /// A day of the month, with or without its ordinal ending ("15", "15th", "1st").
    static func day(_ word: String) -> Int? {
        Int(word.replacingOccurrences(of: #"(st|nd|rd|th)$"#, with: "", options: .regularExpression))
    }

    private func digits(at index: Int) -> (Double, Int)? {
        // "$480,000" and "15th" are numbers too (found on the iPhone).
        let word = tokens[index].word.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: #"(st|nd|rd|th)$"#, with: "", options: .regularExpression)
        guard word.range(of: #"^(\d{1,3}(,\d{3})+|\d+)(\.\d+)?$"#, options: .regularExpression) != nil,
              let value = Double(word.replacingOccurrences(of: ",", with: "")) else { return nil }
        return (value, index)
    }

    private func words(at index: Int) -> (Double, Int)? {
        var parts: [String] = []
        var last = index - 1
        while last + 1 < tokens.count {
            let pieces = tokens[last + 1].word.split(separator: "-").map(String.init)
            guard pieces.allSatisfy(NumberWords.isNumberWord) || (tokens[last + 1].word == "point" && !parts.isEmpty)
            else { break }
            parts += pieces
            last += 1
        }
        if parts.last == "point" {  // "point" with nothing after it is not part of the number
            parts.removeLast()
            last -= 1
        }
        guard !parts.isEmpty, let value = NumberWords.value(parts) else { return nil }
        return (value, last)
    }

    // MARK: making

    private func make(_ first: Int, _ last: Int, value: String, kind: HeardNumber.Kind,
                      unit: String? = nil) -> HeardNumber {
        let start = tokens[first].start, end = tokens[last].end
        let from = tokens[max(0, first - 4)].start
        let until = tokens[min(tokens.count - 1, last + 3)].end  // 4 words before, 3 after (the unit counts)
        return HeardNumber(value: value, words: slice(start, end), unit: unit, kind: kind,
                           context: slice(from, max(until, end)), found: TextSpan(offset: start, length: end - start))
    }

    private func slice(_ start: Int, _ end: Int) -> String {
        let from = transcript.index(transcript.startIndex, offsetBy: start)
        return String(transcript[from..<transcript.index(from, offsetBy: end - start)])
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    static let weekdays: Set = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                                "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]

    static let units: [String: HeardNumber.Kind] = [
        "dollars": .amount, "dollar": .amount, "usd": .amount, "percent": .percent, "cent": .percent,
        "km": .distance, "kilometers": .distance, "kilometres": .distance, "kilomètres": .distance,
        "kilomètre": .distance, "kilometer": .distance,
        "hours": .time, "hour": .time, "heures": .time, "days": .time, "jours": .time, "weeks": .time,
        "semaines": .time, "months": .time, "mois": .time, "years": .time, "ans": .time
    ]
}
