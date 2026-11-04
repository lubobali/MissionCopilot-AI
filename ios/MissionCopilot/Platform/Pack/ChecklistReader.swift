import Foundation

extension ChecklistForm {
    /// Reads a checklist (the pack's forms/road-checklist.json) or says which row to fix.
    static func read(_ data: Data) throws(ChecklistProblem) -> ChecklistForm {
        guard case .object(let root)? = try? JSONValue.parse(data), case .object(let settings)? = root["settings"],
              case .array(let survey)? = root["survey"], let formId = settings.string("form_id"),
              let title = settings.string("form_title"), let version = settings.string("version")
        else { throw .unreadable }
        var reader = ChecklistReader(lists: try ChecklistReader.lists(root["choices"]))
        for (index, row) in survey.enumerated() { try reader.add(row, row: index + 1) }
        let items = try reader.finish()
        try ChecklistReader.checkReferences(in: items, names: reader.names)
        return ChecklistForm(formId: formId, title: title, version: version, items: items, choices: reader.lists,
                             hasFrench: reader.hasFrench)
    }
}

/// Turns KoBo's flat rows into questions and nested groups: a begin_group row opens a group, its
/// end_group row closes it, every other row is a question.
struct ChecklistReader {
    static let french = "::French (fr)"

    let lists: [String: [ChecklistChoice]]
    private(set) var names: Set<String> = []
    private(set) var hasFrench: Bool
    private var open: [(header: Header, items: [ChecklistItem])] = []
    private var top: [ChecklistItem] = []

    /// A group's own row, kept until its end row closes it.
    private struct Header {
        let row: Int, name: String, label: LocalText, relevant: String?
    }

    init(lists: (lists: [String: [ChecklistChoice]], french: Bool)) {
        self.lists = lists.lists
        hasFrench = lists.french
    }

    mutating func add(_ value: JSONValue, row: Int) throws(ChecklistProblem) {
        guard case .object(let fields) = value, let type = fields.string("type") else { throw .unreadable }
        switch type {
        case "end_group":
            guard let closing = open.popLast() else { throw .unbalancedGroup(row: row) }
            let header = closing.header
            append(.group(ChecklistGroup(row: header.row, name: header.name, label: header.label,
                                         relevant: header.relevant, items: closing.items)))
        case "begin_group":
            guard open.count < ChecklistForm.maxDepth else { throw .tooDeep(row: row) }
            let (name, label) = try named(fields, row: row)
            open.append((Header(row: row, name: name, label: label, relevant: fields.string("relevant")), []))
        default:
            append(.question(try question(fields, type: type, row: row)))
        }
    }

    func finish() throws(ChecklistProblem) -> [ChecklistItem] {
        if let unclosed = open.last { throw .unbalancedGroup(row: unclosed.header.row) }
        return top
    }

    private mutating func append(_ item: ChecklistItem) {
        if open.isEmpty { top.append(item) } else { open[open.count - 1].items.append(item) }
    }

    /// A row's name, refused if another row has it, and its label.
    private mutating func named(_ fields: [String: JSONValue], row: Int) throws(ChecklistProblem)
        -> (String, LocalText) {
        guard let name = fields.string("name"), let label = local(fields, "label") else { throw .unreadable }
        guard names.insert(name).inserted else { throw .duplicateName(row: row, name) }
        return (name, label)
    }

    private mutating func question(_ fields: [String: JSONValue], type: String, row: Int) throws(ChecklistProblem)
        -> ChecklistQuestion {
        let kind = try kind(type, list: fields.string("select_from_list_name"), row: row)
        let (name, label) = try named(fields, row: row)
        let required = fields["required"] == .bool(true) || ["yes", "true"].contains(fields.string("required"))
        return ChecklistQuestion(row: row, name: name, kind: kind, label: label, hint: local(fields, "hint"),
                                 required: required, relevant: fields.string("relevant"),
                                 constraint: fields.string("constraint"),
                                 constraintMessage: local(fields, "constraint_message"),
                                 defaultValue: fields.string("default"))
    }

    private func kind(_ type: String, list: String?, row: Int) throws(ChecklistProblem) -> QuestionKind {
        let parts = type.split(separator: " ").map(String.init)
        let simple: [String: QuestionKind] = ["text": .text, "integer": .integer, "decimal": .decimal,
                                              "note": .note, "date": .date, "geopoint": .geopoint, "image": .image]
        if parts.count == 1, let found = simple[type] { return found }
        guard ["select_one", "select_multiple"].contains(parts.first), parts.count <= 2 else {
            throw .unknownType(row: row, type)
        }
        let named = parts.count == 2 ? parts[1] : nil
        guard let chosen = named ?? list, named == nil || list == nil || named == list else { throw .noList(row: row) }
        guard lists[chosen] != nil else { throw .noSuchList(row: row, chosen) }
        return parts[0] == "select_one" ? .selectOne(chosen) : .selectMultiple(chosen)
    }

    private mutating func local(_ fields: [String: JSONValue], _ key: String) -> LocalText? {
        guard let english = fields.string(key) else { return nil }
        let french = fields.string(key + Self.french)
        if french != nil { hasFrench = true }
        return LocalText(english: english, french: french)
    }

    /// The choice lists by name, each choice once, and whether any has a French label.
    static func lists(_ value: JSONValue?) throws(ChecklistProblem)
        -> (lists: [String: [ChecklistChoice]], french: Bool) {
        guard case .array(let rows)? = value else { return ([:], false) }
        var lists: [String: [ChecklistChoice]] = [:], french = false
        for row in rows {
            guard case .object(let fields) = row, let list = fields.string("list_name"),
                  let name = fields.string("name"), let label = fields.string("label") else { throw .unreadable }
            if lists[list]?.contains(where: { $0.name == name }) == true { throw .duplicateChoice(list: list, name) }
            let frenchLabel = fields.string("label" + Self.french)
            french = french || frenchLabel != nil
            lists[list, default: []].append(ChecklistChoice(name: name, label: LocalText(english: label,
                                                                                        french: frenchLabel)))
        }
        return (lists, french)
    }

    /// Every ${name} in a relevant, constraint or default must name a question or group of this form, and no
    /// regex() pattern may be one that could hang the phone (an expression it cannot read is kept, 93.4).
    static func checkReferences(in items: [ChecklistItem], names: Set<String>) throws(ChecklistProblem) {
        for item in items {
            switch item {
            case .question(let question):
                for text in [question.relevant, question.constraint, question.defaultValue].compactMap(\.self) {
                    try check(text, row: question.row, names: names)
                }
            case .group(let group):
                if let relevant = group.relevant { try check(relevant, row: group.row, names: names) }
                try checkReferences(in: group.items, names: names)
            }
        }
    }

    private static func check(_ text: String, row: Int, names: Set<String>) throws(ChecklistProblem) {
        for match in text.matches(of: /\$\{([^}]*)\}/) where !names.contains(String(match.1)) {
            throw .unknownReference(row: row, String(match.1))
        }
        do { _ = try ChecklistExpression.read(text) } catch { throw .unsafePattern(row: row) }
    }
}

private extension [String: JSONValue] {
    func string(_ key: String) -> String? {
        if case .string(let text)? = self[key] { text } else { nil }
    }
}
