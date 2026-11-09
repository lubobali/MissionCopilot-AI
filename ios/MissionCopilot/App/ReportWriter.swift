import Foundation

/// A report's sections, in a World Bank aide-memoire's order (#161, from a real 2025 aide-memoire: introduction,
/// project information, main mission findings, the agreed actions since the last mission, next steps).
enum ReportSection: String, CaseIterable, Codable, Sendable {
    case mission, project, findings, agreedActions, nextSteps

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    func title(_ language: AnswerLanguage) -> String {
        switch self {
        case .mission: "Mission"
        case .project: language.pick("Project information", "Informations sur le projet")
        case .findings: language.pick("Main findings", "Principales constatations")
        case .agreedActions: language.pick("Agreed actions since the last mission",
                                           "Actions convenues depuis la dernière mission")
        case .nextSteps: language.pick("Next steps", "Prochaines étapes")
        }
    }
}

/// One report sentence: its section, its words, the facts it cites, and whether Ask's check backs it.
struct ReportLine: Equatable, Sendable, Identifiable {
    let section: ReportSection
    let text: String
    let factIds: [String]
    /// No number or month that its record does not hold (#161, AnswerCheck's number and month rules).
    let checked: Bool
    /// Why the check did not back it, when it did not.
    var reason: String?
    var id: String { section.rawValue + "|" + text }
}

/// The report written by code (#161, step 7.2.1; ADR 0005): each fact the report uses becomes one sentence in
/// Ask's checked words (AnswerLines), in its section, citing its fact. Templates, never the model: the faithful
/// way to write from records (INLG 2024: rule and template systems make the fewest semantic errors).
enum ReportWriter {
    /// `sources` are Ask's sources for the mission (pack, walk, flags, scanned and debrief facts); `facts` are the
    /// mission's facts, report facts included; `flagged` the names of the red flags that are raised. Short, like a
    /// real aide-memoire (#161, 7.2.7, found on the iPhone: 77 sentences): a scanned invoice is one sentence, and
    /// the same sentence twice is one citing both.
    static func write(sources: [MissionSource], facts: [Fact], flagged: Set<String>,
                      language: AnswerLanguage) -> [ReportLine] {
        let byName = Dictionary(facts.map { ($0.name, $0) }) { first, _ in first }
        let byId = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        let scanOf = scans(facts)
        var lines: [ReportLine] = []
        var scanned: [Int: ScanLine] = [:]
        for source in sources {
            guard let section = section(of: source, flagged: flagged, byId: byId),
                  let fact = fact(for: source, byName: byName, byId: byId) else { continue }
            if let scan = scanOf[fact.id] {
                if scanned[scan] == nil {
                    scanned[scan] = ScanLine(position: lines.count)
                    lines.append(ReportLine(section: section, text: "", factIds: [], checked: false))
                }
                scanned[scan]?.add(source, fact)
                continue
            }
            lines.append(codeLine(section, AnswerLines.line(source, language: language).text, [source], [fact]))
        }
        for scan in scanned.values {
            lines[scan.position] = codeLine(.findings, scan.text(language), scan.sources, scan.facts)
        }
        return once(lines).enumerated().sorted { first, second in
            (first.element.section.order, first.offset) < (second.element.section.order, second.offset)
        }.map(\.element)
    }

    private static func codeLine(_ section: ReportSection, _ text: String, _ sources: [MissionSource],
                                 _ facts: [Fact]) -> ReportLine {
        let reason = numberOrMonth(text, sources: sources)
        return ReportLine(section: section, text: text, factIds: facts.map(\.id), checked: reason == nil,
                          reason: reason)
    }

    /// Which scanned invoice each scanned fact belongs to: an invoice's 8 facts are stored together, in order,
    /// so a field seen again starts the next invoice.
    static func scans(_ facts: [Fact]) -> [String: Int] {
        var scan = 0
        var seen: Set<String> = []
        var out: [String: Int] = [:]
        for fact in facts where InvoiceFacts.fields.contains(fact.name)
            && (fact.rule == MissionStore.scanRule || fact.rule == MissionStore.officerRule) {
            if seen.contains(fact.name) {
                scan += 1
                seen = []
            }
            seen.insert(fact.name)
            out[fact.id] = scan
        }
        return out
    }

    /// The same sentence in the same section once, at its first place, citing every fact of each copy.
    private static func once(_ lines: [ReportLine]) -> [ReportLine] {
        var out: [ReportLine] = []
        var place: [String: Int] = [:]
        for line in lines {
            guard let index = place[line.id] else {
                place[line.id] = out.count
                out.append(line)
                continue
            }
            let kept = out[index]
            let ids = kept.factIds + line.factIds.filter { !kept.factIds.contains($0) }
            out[index] = ReportLine(section: kept.section, text: kept.text, factIds: ids,
                                    checked: kept.checked && line.checked, reason: kept.reason ?? line.reason)
        }
        return out
    }

    /// The officer's own sentence (#161, step 7.2.3), checked in full by Ask's check (AnswerCheck: numbers,
    /// dates, months, status words and their opposite, the main words) against the facts they picked; one that
    /// fails or picks no fact keeps the reason, and is never stored.
    static func officerLine(section: ReportSection, text: String, factIds: [String], sources: [MissionSource],
                            facts: [Fact]) -> ReportLine {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !factIds.isEmpty else {
            return ReportLine(section: section, text: words, factIds: [], checked: false, reason: pickFacts)
        }
        let byId = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        let byName = Dictionary(sources.map { ($0.id, $0) }) { first, _ in first }
        let cited = factIds.compactMap { id in
            byId[id].flatMap { byName[$0.name] ?? byName["fact:\(id)"] }
        }
        let reason: String? = switch AnswerCheck.check(words, cites: cited.map(\.id), found: cited) {
        case .backed: nil
        case .leftOut(let why): why
        }
        return ReportLine(section: section, text: words, factIds: factIds, checked: reason == nil, reason: reason)
    }

    static let pickFacts = "Pick the facts this sentence comes from."

    /// Code's own lines: every number and month must be in the record (the rule Ask's code lines meet,
    /// AnswerLinesTests); statuses come straight from the record's fields and names (a milestone named
    /// "Section 3 bridge complete" is a name, not a claim). The officer's sentences get the full check.
    static func numberOrMonth(_ text: String, source: MissionSource) -> String? {
        numberOrMonth(text, sources: [source])
    }

    static func numberOrMonth(_ text: String, sources: [MissionSource]) -> String? {
        guard case .leftOut(let why) = AnswerCheck.check(text, cites: sources.map(\.id), found: sources),
              why.hasPrefix("The number") || why.hasPrefix("The month") else { return nil }
        return why
    }

    /// The fact a source is written from: the report fact of the same name (pack, walk, flag), or the confirmed
    /// fact itself (a scanned invoice's field, a debrief note).
    private static func fact(for source: MissionSource, byName: [String: Fact], byId: [String: Fact]) -> Fact? {
        if source.id.hasPrefix("fact:") { return byId[String(source.id.dropFirst("fact:".count))] }
        return byName[source.id]
    }

    private static func section(of source: MissionSource, flagged: Set<String>,
                                byId: [String: Fact]) -> ReportSection? {
        let id = source.id
        switch source.kind {
        case .pack:
            if id.range(of: #"#/contracts/\d+$"#, options: .regularExpression) != nil { return .mission }
            // Only the overall rating, which every pack has (pack-sections schema); the rest is in the pack.
            if id.hasSuffix("#paid") || id.hasSuffix("ratings.json#/overallRisk") || id.hasSuffix("physicalProgress")
                || id.range(of: #"#/milestones/\d+$"#, options: .regularExpression) != nil { return .project }
            if id.range(of: #"#/actions/\d+$"#, options: .regularExpression) != nil { return .agreedActions }
            return nil
        case .walkAnswer:
            return id.hasPrefix("walk:action-") ? .agreedActions : .findings
        case .redFlag:
            return flagged.contains(id) ? .findings : nil
        case .note:
            let kind = byId[String(id.dropFirst("fact:".count))]?.name
            return kind == "debrief.action" ? .nextSteps : .findings
        case .fact:
            return source.title.hasPrefix("Scanned invoice") || source.title.hasPrefix(MissionSources.typedTitle)
                ? .findings : nil
        case .document:
            return nil
        }
    }
}

/// One scanned invoice's facts, gathered into one sentence in the invoice's field order.
private struct ScanLine {
    let position: Int
    var sources: [MissionSource] = []
    var facts: [Fact] = []

    mutating func add(_ source: MissionSource, _ fact: Fact) {
        sources.append(source)
        facts.append(fact)
    }

    /// "From your scanned invoice: Invoice number: 14; …; Road built: 32 km; …", a typed value marked as such.
    func text(_ language: AnswerLanguage) -> String {
        let order = { (fact: Fact) in InvoiceFacts.fields.firstIndex(of: fact.name) ?? 0 }
        let parts = facts.sorted { order($0) < order($1) }.map { fact in
            "\(InvoiceFacts.name(fact.name)): \(InvoiceFacts.words(fact.name, value: fact.value))"
                + (fact.typedNotOnPage ? language.pick(" (typed by you, not on the page)",
                                                       " (saisi par vous, pas sur la page)") : "")
        }
        return language.pick("From your scanned invoice: ", "Selon votre facture scannée : ")
            + parts.joined(separator: "; ") + "."
    }
}
