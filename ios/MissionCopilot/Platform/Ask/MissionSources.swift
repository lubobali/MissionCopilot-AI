import Foundation

/// Where a source came from, so an answer can show exactly what it cites (#145).
enum SourceOrigin: Equatable, Sendable {
    case pack(PackCitation)
    case document(path: String, paragraph: Int)
    case fact(id: String, sources: [FactSource])
    case walk(question: String)
    case redFlag(rule: String)
}

/// One piece of the mission's data as a short text: what a question searches and an answer cites.
struct MissionSource: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case pack, document, fact, note, walkAnswer, redFlag }

    let id: String
    let kind: Kind
    let title: String
    let text: String
    let origin: SourceOrigin
}

/// A line already in the officer's words (a walk answer with its question, a red flag's sentence).
struct WordedLine: Equatable, Sendable {
    let key: String
    let title: String
    let text: String
}

/// What the sources are built from: the signed pack's files and the confirmed records.
struct SourceInputs: Sendable {
    var packFiles: [String: Data] = [:]
    var facts: [Fact] = []
    var walk: [WordedLine] = []
    var flags: [WordedLine] = []
}

/// The mission's sources (#145, step 6.7.1), built in memory every time: pack JSON objects cited by their
/// JSON Pointer, document paragraphs, confirmed facts and notes, walk answers and red flags. Nothing is stored.
enum MissionSources {
    static func build(_ inputs: SourceInputs) -> [MissionSource] {
        var sources: [MissionSource] = []
        for path in inputs.packFiles.keys.sorted() {
            guard let data = inputs.packFiles[path] else { continue }
            if path.hasPrefix("sections/"), let root = try? JSONValue.parse(data) {
                sources += PackSourceReader(file: PackFileRef(path: path, data: data)).sources(root)
            } else if path.hasPrefix("documents/"), let text = String(data: data, encoding: .utf8) {
                sources += paragraphs(text, path: path)
            }
        }
        sources += inputs.facts.map(fact)
        sources += inputs.walk.map { line in
            MissionSource(id: "walk:\(line.key)", kind: .walkAnswer, title: line.title,
                          text: "\(line.title) \(line.text)", origin: .walk(question: line.key))
        }
        var seen: [String: Int] = [:]
        sources += inputs.flags.map { line in
            let count = seen[line.key, default: 0]
            seen[line.key] = count + 1
            return MissionSource(id: "flag:\(line.key):\(count)", kind: .redFlag, title: line.title, text: line.text,
                                 origin: .redFlag(rule: line.key))
        }
        return sources
    }

    /// A document's paragraphs (blank-line blocks), numbered from 1; a heading alone or the fictional-data
    /// disclaimer is not a source, but keeps its number so each paragraph is cited by its place.
    static func paragraphs(_ text: String, path: String) -> [MissionSource] {
        let blocks = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let heading = blocks.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? path
        return blocks.enumerated().compactMap { index, block in
            let headingOnly = block.hasPrefix("#") && !block.contains("\n")
            guard !headingOnly, !block.hasPrefix("Fictional:") else { return nil }
            return MissionSource(id: "doc:\(path)#\(index + 1)", kind: .document,
                                 title: "\(heading) · paragraph \(index + 1)", text: block,
                                 origin: .document(path: path, paragraph: index + 1))
        }
    }

    /// A confirmed fact in words: a scanned invoice's field, a debrief note, or a number heard in a debrief.
    static func fact(_ fact: Fact) -> MissionSource {
        let origin = SourceOrigin.fact(id: fact.id, sources: fact.sources)
        if fact.name.hasPrefix("debrief."), let data = fact.value.data(using: .utf8),
           let note = try? JSONDecoder().decode(NoteValue.self, from: data) {
            let kind = String(fact.name.dropFirst("debrief.".count)).capitalized
            let text = [note.text, note.who.isEmpty ? nil : "Who: \(note.who).",
                        note.byWhen.isEmpty ? nil : "By when: \(note.byWhen)."].compactMap { $0 }.joined(separator: " ")
            return MissionSource(id: "fact:\(fact.id)", kind: .note, title: "Debrief note · \(kind)", text: text,
                                 origin: origin)
        }
        let value = fact.value + (fact.unit.map { " \($0)" } ?? "")
        if fact.name.hasPrefix("spoken.") {
            let kind = String(fact.name.dropFirst("spoken.".count)).capitalized
            return MissionSource(id: "fact:\(fact.id)", kind: .fact, title: "Heard in a debrief · \(kind)", text: value,
                                 origin: origin)
        }
        let name = InvoiceFacts.name(fact.name)
        return MissionSource(id: "fact:\(fact.id)", kind: .fact, title: "Scanned invoice · \(name)",
                             text: "\(name): \(value)", origin: origin)
    }
}

/// One pack section's JSON as sources: every object with plain fields is one source, cited by its pointer.
private struct PackSourceReader {
    let file: PackFileRef

    func sources(_ root: JSONValue) -> [MissionSource] {
        walk(root, path: [])
    }

    private func walk(_ value: JSONValue, path: [String]) -> [MissionSource] {
        switch value {
        case .object(let fields):
            let lines = fields.keys.sorted().compactMap { key in
                fields[key].flatMap(plain).map { "\(words(key)): \($0)" }
            }
            let here = lines.isEmpty ? [] : [source(path: path, text: lines.joined(separator: "\n"))]
            return here + paidToDate(fields["payments"], path: path + ["payments"])
                + fields.keys.sorted().flatMap { key in walk(fields[key] ?? .null, path: path + [key]) }
        case .array(let items):
            return items.enumerated().flatMap { index, item in walk(item, path: path + [String(index)]) }
        default:
            return []
        }
    }

    /// A contract's payments added up by code (ADR 0005: the model never does arithmetic), citing the list.
    private func paidToDate(_ payments: JSONValue?, path: [String]) -> [MissionSource] {
        guard case .array(let items)? = payments, !items.isEmpty else { return [] }
        let amounts = items.compactMap { item -> Double? in
            if case .object(let fields) = item, case .number(let amount)? = fields["amount"] { return amount }
            return nil
        }
        guard amounts.count == items.count else { return [] }
        let base = source(path: path, text: "")
        let total = Self.number(amounts.reduce(0, +))
        return [MissionSource(id: base.id + "#paid", kind: .pack,
                              title: base.title.replacingOccurrences(of: " › payments", with: " › paid to date"),
                              text: "paid to date: \(total) (the sum of the pack's \(items.count) payments, "
                                  + "added by the app)",
                              origin: base.origin)]
    }

    /// A field's value when it is plain (a word, a number, yes or no, or a list of those).
    private func plain(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): text
        case .number(let number): Self.number(number)
        case .bool(let flag): flag ? "yes" : "no"
        case .array(let items):
            Self.list(items.map { isContainer($0) ? nil : plain($0) })
        case .null, .object: nil
        }
    }

    /// A whole number without ".0" ("10000000"), otherwise as it is.
    private static func number(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(value)
    }

    /// A list of plain values as one line; nil when it is empty or holds anything else.
    private static func list(_ values: [String?]) -> String? {
        let words = values.compactMap { $0 }
        return words.isEmpty || words.count != values.count ? nil : words.joined(separator: ", ")
    }

    private func isContainer(_ value: JSONValue) -> Bool {
        switch value {
        case .array, .object: true
        default: false
        }
    }

    private func source(path: [String], text: String) -> MissionSource {
        let pointer = "/" + path.joined(separator: "/")
        let stem = file.path.split(separator: "/").last.map { $0.replacingOccurrences(of: ".json", with: "") } ?? ""
        var parts = [words(stem).capitalized]
        for component in path {
            if let index = Int(component), let last = parts.popLast() {
                parts.append("\(last) \(index + 1)")
            } else {
                parts.append(words(component))
            }
        }
        return MissionSource(id: "pack:\(file.path)#\(path.isEmpty ? "" : pointer)", kind: .pack,
                             title: parts.joined(separator: " › "), text: text,
                             origin: .pack(file.cite(path.isEmpty ? "" : pointer)))
    }

    /// "contractValue" as "contract value", "agreed-actions" as "agreed actions".
    private func words(_ key: String) -> String {
        var out = ""
        for character in key {
            if character.isUppercase {
                out += " " + character.lowercased()
            } else if character == "-" || character == "_" {
                out += " "
            } else {
                out.append(character)
            }
        }
        return out
    }
}
