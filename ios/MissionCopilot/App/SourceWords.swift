import Foundation

/// A source as a person reads it: a title, a few lines, and where it came from in words.
struct SourceCardWords: Equatable, Sendable {
    let title: String
    let lines: [String]
    let place: String
}

/// Sources in words (#145, step 6.7.3, after Lubo's first look on the iPhone: no JSON Pointers, hashes, raw
/// tables or repeated text). Money gets its currency and commas, dates are written out, a document table
/// becomes rows, and rows of one kind (a contract's payments) are grouped into one card.
enum SourceWords {
    /// The Kandor pack's sections all state USD; the schema keeps one currency per pack.
    static let currency = "USD"

    static func card(_ source: MissionSource) -> SourceCardWords {
        switch source.origin {
        case .pack(let citation): pack(source, citation: citation)
        case .document(let path, let paragraph): document(source, path: path, paragraph: paragraph)
        case .walk:
            SourceCardWords(title: source.title, lines: [answer(source)], place: "Your site walk")
        case .fact:
            SourceCardWords(title: source.title, lines: [source.text],
                            place: source.kind == .note ? "Your confirmed debrief" : "Confirmed by you")
        case .redFlag(let rule):
            SourceCardWords(title: source.title, lines: [source.text], place: "Red flag rule \(rule)")
        }
    }

    /// The best sources as cards, in order; two or more rows of one list (payments) become one card.
    static func group(_ hits: [SearchHit]) -> [SourceCardWords] {
        let keys = hits.map { listKey($0.source) }
        var cards: [SourceCardWords] = [], done: Set<String> = []
        for (index, hit) in hits.enumerated() {
            guard let key = keys[index], keys.filter({ $0 == key }).count > 1 else {
                cards.append(card(hit.source))
                continue
            }
            guard done.insert(key).inserted else { continue }
            let rows = hits.indices.filter { keys[$0] == key }.map { row(hits[$0].source) }
            let first = card(hit.source)
            let label = first.title.components(separatedBy: " · ").first ?? first.title
            cards.append(SourceCardWords(title: "\(plural(label)) (\(rows.count))", lines: rows, place: first.place))
        }
        return cards
    }

    // MARK: values

    /// A value in words: money with its currency and commas, other numbers with commas, a day written out.
    static func value(_ raw: String, key: String) -> String {
        if let day = FactGrounding.isoDay.date(from: raw), raw.count == 10 {
            return FactGrounding.formatter("d MMM yyyy").string(from: day)
        }
        guard let number = Int(raw) else { return raw }
        let grouped = InvoiceChecks.money(number)
        return moneyWords.contains { key.hasSuffix($0) } ? "\(currency) \(grouped)" : grouped
    }

    private static let moneyWords = ["amount", "value", "cost", "disbursed", "budget", "original", "revised",
                                     "cancelled", "undisbursed"]
}

extension SourceWords {
    private static let names = ["payments": "Payment", "actions": "Agreed action", "milestones": "Milestone",
                                "components": "Component", "indicators": "Result", "commitments": "Commitment",
                                "grievances": "Grievance", "locations": "Location", "contracts": "Contract"]
    private static let nameFields = ["reference", "title", "action", "name", "indicator", "description", "category"]

    private static func fields(_ text: String) -> [(key: String, value: String)] {
        text.split(separator: "\n").compactMap { line in
            guard let colon = line.range(of: ": ") else { return nil }
            return (String(line[..<colon.lowerBound]), String(line[colon.upperBound...]))
        }
    }

    private static func path(_ citation: PackCitation) -> [String] {
        citation.pointer.split(separator: "/").map(String.init)
    }

    private static func section(_ citation: PackCitation) -> String {
        (citation.path.split(separator: "/").last.map(String.init) ?? citation.path)
            .replacingOccurrences(of: ".json", with: "").replacingOccurrences(of: "-", with: " ")
    }

    private static func pack(_ source: MissionSource, citation: PackCitation) -> SourceCardWords {
        let place = "Bank record · \(section(citation))"
        if source.id.hasSuffix("#paid") {
            let parts = source.text.replacingOccurrences(of: "paid to date: ", with: "").components(separatedBy: " (")
            let total = value(parts.first ?? "", key: "amount")
            return SourceCardWords(title: "Paid to date",
                                   lines: ["\(total), " + (parts.dropFirst().first?.dropLast() ?? "")], place: place)
        }
        let all = fields(source.text)
        let components = path(citation)
        var title = section(citation).capitalized
        var shown = all
        if let last = components.last, Int(last) != nil, components.count >= 2 {
            let list = components[components.count - 2]
            title = names[list] ?? String(words(list).capitalized.dropLast())
            if let name = nameFields.lazy.compactMap({ field in all.first { $0.key == field } }).first {
                title += " · \(name.value)"
                shown = all.filter { $0.key != name.key }
            }
        } else if let last = components.last {
            title += " · \(words(last).capitalized(firstOnly: true))"
        }
        return SourceCardWords(title: title, lines: shown.map { "\($0.key.capitalized(firstOnly: true)): "
            + value($0.value, key: $0.key) }, place: place)
    }

    private static func document(_ source: MissionSource, path: String, paragraph: Int) -> SourceCardWords {
        let lines = source.text.split(separator: "\n").map(String.init).compactMap { line -> String? in
            if line.hasPrefix("|") {
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard !cells.allSatisfy({ $0.allSatisfy { "-:".contains($0) } }) else { return nil }
                return cells.map { value($0, key: "") }.joined(separator: " · ")
            }
            return line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
        }
        // A table's first row names its columns: the rows say enough on their own.
        let rows = source.text.hasPrefix("|") ? Array(lines.dropFirst()) : lines
        return SourceCardWords(title: "\(documentName(path)) · paragraph \(paragraph)", lines: rows,
                               place: "Document in the mission pack")
    }

    /// "documents/aide-memoire-2026-05.md" as "Aide memoire, May 2026".
    static func documentName(_ path: String) -> String {
        let stem = (path.split(separator: "/").last.map(String.init) ?? path).replacingOccurrences(of: ".md", with: "")
        guard let match = stem.range(of: #"-(\d{4})-(\d{2})$"#, options: .regularExpression),
              let month = FactGrounding.formatter("yyyy-MM").date(from: String(stem[match].dropFirst())) else {
            return stem.replacingOccurrences(of: "-", with: " ").capitalized(firstOnly: true)
        }
        return stem[..<match.lowerBound].replacingOccurrences(of: "-", with: " ").capitalized(firstOnly: true)
            + ", " + FactGrounding.formatter("MMM yyyy").string(from: month)
    }

    /// A walk answer without its question repeated, starting with a capital.
    private static func answer(_ source: MissionSource) -> String {
        let text = source.text.hasPrefix(source.title)
            ? String(source.text.dropFirst(source.title.count)).trimmingCharacters(in: .whitespaces) : source.text
        return text.capitalized(firstOnly: true)
    }

    /// The list a pack row belongs to ("/contracts/0/payments"), for grouping; nil for anything else.
    private static func listKey(_ source: MissionSource) -> String? {
        guard case .pack(let citation) = source.origin, !source.id.hasSuffix("#paid") else { return nil }
        let components = path(citation)
        guard let last = components.last, Int(last) != nil else { return nil }
        return citation.path + "#" + components.dropLast().joined(separator: "/")
    }

    /// One row of a grouped card: its name, then its values ("Invoice 14 · USD 480,000 · 12 Oct 2026").
    private static func row(_ source: MissionSource) -> String {
        let all = fields(source.text)
        let name = nameFields.lazy.compactMap { field in all.first { $0.key == field } }.first
        let rest = all.filter { $0.key != name?.key }.map { value($0.value, key: $0.key) }
        return ([name?.value].compactMap { $0 } + rest).joined(separator: " · ")
    }

    private static func plural(_ word: String) -> String { word.hasSuffix("s") ? word : word + "s" }

    private static func words(_ key: String) -> String {
        key.reduce(into: "") { out, character in
            out += character.isUppercase ? " " + character.lowercased() : String(character)
        }
    }
}

extension String {
    /// Only the first letter made a capital ("contract value" as "Contract value").
    func capitalized(firstOnly: Bool) -> String {
        guard firstOnly, let first else { return capitalized }
        return first.uppercased() + dropFirst()
    }
}
