import Foundation

/// Each extracted fact must appear in the scanned text in a printed form, or it is "ungrounded" and goes
/// to a person for review (ADR 0009: an untraceable claim cannot be approved). Pure code, no model.
public enum Grounding {
    public struct Report: Equatable, Sendable {
        /// Field name -> the exact text in the scan that backs it.
        public let grounded: [String: String]
        /// Field names with no backing text, in schema order.
        public let ungrounded: [String]
    }

    public static func check(_ facts: ExtractedFacts, in source: String) -> Report {
        let text = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let candidates: [(String, [String])] = [
            ("invoiceNumber", invoiceNumber(facts.invoiceNumber)),
            ("invoiceDate", date(facts.invoiceDate)),
            ("amountDue", money(facts.amountDue)),
            ("cumulativePaid", money(facts.cumulativePaid)),
            ("contractValue", money(facts.contractValue)),
            ("kmCompleted", ["(?<!\\d)\(facts.kmCompleted) of \\d+ km", "(?<!\\d)\(facts.kmCompleted) km"]),
            ("kmTotal", ["of \(facts.kmTotal) km", "(?<!\\d)\(facts.kmTotal) km"]),
            ("bridgeStatus", bridge(facts.bridgeStatus)),
        ]
        var grounded: [String: String] = [:]
        var ungrounded: [String] = []
        for (field, patterns) in candidates {
            if let evidence = patterns.lazy.compactMap({ firstMatch($0, in: text) }).first {
                grounded[field] = evidence
            } else {
                ungrounded.append(field)
            }
        }
        return Report(grounded: grounded, ungrounded: ungrounded)
    }

    /// "14" must stand alone: "Invoice No. 1" is not found inside "Invoice No. 14".
    static func invoiceNumber(_ number: String) -> [String] {
        let value = NSRegularExpression.escapedPattern(for: number)
        return ["Invoice No\\.? ?\(value)(?!\\d)", "Invoice #?\(value)(?!\\d)"]
    }

    /// The printed forms of an ISO date: "12 October 2026", "12 Oct 2026", "October 12, 2026", "2026-10-12".
    static func date(_ iso: String) -> [String] {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let day = parser.date(from: iso) else { return [] }
        return ["d MMMM yyyy", "d MMM yyyy", "MMMM d, yyyy", "yyyy-MM-dd"].map { format in
            parser.dateFormat = format
            return "(?<!\\d)" + NSRegularExpression.escapedPattern(for: parser.string(from: day)) + "(?!\\d)"
        }
    }

    /// "480,000" or "480000", never part of a bigger number like "1,480,000".
    static func money(_ amount: Int) -> [String] {
        let grouped = amount.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        return [grouped, String(amount)].map { "(?<![\\d.,])" + NSRegularExpression.escapedPattern(for: $0) + "(?![\\d]|[.,]\\d)" }
    }

    /// Only the status line counts ("Section 3 bridge: not started"), not a table row that happens to
    /// contain a status word (the milestone "Section 3 bridge complete").
    static func bridge(_ status: String) -> [String] {
        let words: [String] = switch status {
        case "not_started": ["not started", "not yet started"]
        case "in_progress": ["in progress", "under construction", "under way", "ongoing"]
        case "completed": ["completed", "complete", "finished"]
        default: []
        }
        return words.map { "bridge[^:|]{0,30}: ?\($0)\\b" }
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }
}
