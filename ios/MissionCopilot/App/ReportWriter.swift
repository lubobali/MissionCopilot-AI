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
    /// mission's facts, report facts included; `flagged` the names of the red flags that are raised.
    static func write(sources: [MissionSource], facts: [Fact], flagged: Set<String>,
                      language: AnswerLanguage) -> [ReportLine] {
        let byName = Dictionary(facts.map { ($0.name, $0) }) { first, _ in first }
        let byId = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        let lines = sources.compactMap { source -> ReportLine? in
            guard let section = section(of: source, flagged: flagged, byId: byId),
                  let fact = fact(for: source, byName: byName, byId: byId) else { return nil }
            let text = AnswerLines.line(source, language: language).text
            let reason = numberOrMonth(text, source: source)
            return ReportLine(section: section, text: text, factIds: [fact.id], checked: reason == nil,
                              reason: reason)
        }
        return lines.enumerated().sorted { first, second in
            (first.element.section.order, first.offset) < (second.element.section.order, second.offset)
        }.map(\.element)
    }

    /// Code's own lines: every number and month must be in the record (the rule Ask's code lines meet,
    /// AnswerLinesTests); statuses come straight from the record's fields and names (a milestone named
    /// "Section 3 bridge complete" is a name, not a claim). The officer's sentences get the full check.
    static func numberOrMonth(_ text: String, source: MissionSource) -> String? {
        guard case .leftOut(let why) = AnswerCheck.check(text, cites: [source.id], found: [source]),
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
            if id.hasSuffix("#paid") || id.contains("ratings.json#/") || id.hasSuffix("physicalProgress")
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
