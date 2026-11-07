import Foundation

/// Where a fact is printed: the page (its order in the scan), the position in that page's text
/// (FactGrounding.text, counted in characters) and the printed words themselves. A position, never a copy
/// to trust: the sealed reading is the source, and this points into it (#138).
struct PrintedAt: Codable, Sendable, Equatable {
    let page: Int
    let offset: Int
    let text: String
}

/// Grounding and the code's second opinion (#138, step 6.5.8, from spikes #13, #15 and #8). Pure code, no
/// model: a fact not printed on a page is ungrounded, and a fixed label the code reads with another value
/// sends the fact to the officer even when the model's value is printed somewhere else.
enum FactGrounding {
    /// One page as one line: its text, then each table row as cells joined by " | ", every run of white space
    /// made one space (Vision breaks lines where the paper does).
    static func text(_ page: PageReading) -> String {
        let rows = page.tables.flatMap { $0.map { $0.joined(separator: " | ") } }
        return ([page.transcript] + rows).joined(separator: "\n").split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Each fact that is printed on a page, with where; a missing field is ungrounded.
    static func sources(_ facts: InvoiceFacts, in pages: [PageReading]) -> [String: PrintedAt] {
        let texts = pages.map(text)
        var found: [String: PrintedAt] = [:]
        for (field, patterns) in printedForms(facts) {
            found[field] = texts.indices.lazy.compactMap { page in
                patterns.lazy.compactMap { first($0, in: texts[page]) }.first
                    .map { PrintedAt(page: page, offset: $0.offset, text: $0.text) }
            }.first
        }
        return found
    }

    static func printedForms(_ facts: InvoiceFacts) -> [(String, [String])] {
        let number = NSRegularExpression.escapedPattern(for: facts.invoiceNumber)
        return [
            ("invoiceNumber", ["Invoice No\\.? ?\(number)(?!\\d)", "Invoice #?\(number)(?!\\d)"]),
            ("invoiceDate", printedDates(facts.invoiceDate)),
            ("amountDue", money(facts.amountDue)),
            ("cumulativePaid", money(facts.cumulativePaid)),
            ("contractValue", money(facts.contractValue)),
            ("kmCompleted", ["(?<!\\d)\(facts.kmCompleted) of \\d+ km", "(?<!\\d)\(facts.kmCompleted) km"]),
            ("kmTotal", ["of \(facts.kmTotal) km", "(?<!\\d)\(facts.kmTotal) km"]),
            ("bridgeStatus", bridgeWords[facts.bridgeStatus, default: []].map { "bridge[^:|]{0,30}: ?\($0)\\b" })
        ]
    }

    /// The printed forms of an ISO date: "12 October 2026", "12 Oct 2026", "October 12, 2026", "2026-10-12".
    static func printedDates(_ iso: String) -> [String] {
        guard let day = isoDay.date(from: iso) else { return [] }
        return dateFormats.map { format in
            "(?<!\\d)" + NSRegularExpression.escapedPattern(for: formatter(format).string(from: day)) + "(?!\\d)"
        }
    }

    /// "480,000" or "480000", never part of a bigger number like "1,480,000".
    static func money(_ amount: Int) -> [String] {
        [amount.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))), String(amount)].map {
            "(?<![\\d.,])" + NSRegularExpression.escapedPattern(for: $0) + "(?![\\d]|[.,]\\d)"
        }
    }

    static let bridgeWords = ["not_started": ["not started", "not yet started"],
                              "in_progress": ["in progress", "under construction", "under way", "ongoing"],
                              "completed": ["completed", "complete", "finished"]]

    static func first(_ pattern: String, in text: String) -> (offset: Int, text: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return (text.distance(from: text.startIndex, to: range.lowerBound), String(text[range]))
    }
}

extension FactGrounding {
    /// The fixed labels the code reads by itself: each field and the value printed after its label.
    static let labels: [(field: String, pattern: String)] = [
        ("amountDue", #"(?:amount|total)[^:|]{0,30}\bdue\b[^:|]{0,30}:\s*(?:USD\s*)?(\#(amount))"#),
        ("cumulativePaid", #"paid to date[^:|]{0,40}:\s*(?:USD\s*)?(\#(amount))"#),
        ("contractValue", #"contract value[^:|]{0,30}:\s*(?:USD\s*)?(\#(amount))"#),
        ("invoiceDate", #"\bdate:\s*(\d{1,2} [A-Za-z]+ \d{4}|[A-Za-z]+ \d{1,2}, \d{4}|\d{4}-\d{2}-\d{2})"#),
        ("kmCompleted", #"road built:\s*(\d+)"#),
        ("kmTotal", #"road built:\s*\d+\s+of\s+(\d+)"#)
    ]
    private static let amount = #"\d{1,3}(?:,\d{3})+|\d+"#

    /// Every value the code read after each label, in page order (a label printed twice is read twice).
    static func labelled(in pages: [PageReading]) -> [String: [String]] {
        let texts = pages.map(text)
        var read: [String: [String]] = [:]
        for (field, pattern) in labels {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let values = texts.flatMap { text in
                regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                    Range($0.range(at: 1), in: text).map { String(text[$0]) }
                }
            }
            if !values.isEmpty { read[field] = values }
        }
        return read
    }

    /// The fields where the code read something else than the model (or read two values), with what the code
    /// read; a label the code did not find gives no opinion.
    static func secondOpinion(_ facts: InvoiceFacts, in pages: [PageReading]) -> [String: String] {
        let model: [String: String] = [
            "amountDue": String(facts.amountDue), "cumulativePaid": String(facts.cumulativePaid),
            "contractValue": String(facts.contractValue), "invoiceDate": facts.invoiceDate,
            "kmCompleted": String(facts.kmCompleted), "kmTotal": String(facts.kmTotal)
        ]
        return labelled(in: pages).filter { field, values in
            let normal = Set(values.map { normalized($0, field: field) })
            return normal.count > 1 || normal.first != model[field]
        }.mapValues { values in values.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " or ") }
    }

    /// A printed value in the model's form: amounts without commas, dates as YYYY-MM-DD.
    static func normalized(_ printed: String, field: String) -> String {
        guard field == "invoiceDate" else { return printed.replacingOccurrences(of: ",", with: "") }
        for format in dateFormats {
            if let day = formatter(format).date(from: printed) { return isoDay.string(from: day) }
        }
        return printed
    }

    static let dateFormats = ["d MMMM yyyy", "d MMM yyyy", "MMMM d, yyyy", "yyyy-MM-dd"]

    static var isoDay: DateFormatter { formatter("yyyy-MM-dd") }

    /// Dates as printed on English paper, in UTC so a day never moves.
    static func formatter(_ format: String) -> DateFormatter {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .gmt
        parser.dateFormat = format
        return parser
    }
}
