import Foundation
import Testing
@testable import MissionCopilot

/// The report by code (#161, step 7.2.1): the mission's facts become an aide-memoire's sections (from a real
/// World Bank aide-memoire: mission, project information, main findings, agreed actions since the last mission,
/// next steps), each sentence written by code in Ask's checked words and citing its facts.
@MainActor
struct ReportWriterTests {
    static let mission = PackDownloaderTests.mission

    /// The finished Kandor walk with its flags, its report facts and Ask's sources for it.
    static func kandor(language: AnswerLanguage = .english) async throws -> [ReportLine] {
        try await kandorWithFacts(language: language).lines
    }

    static func kandorWithFacts(language: AnswerLanguage = .english) async throws
        -> (lines: [ReportLine], facts: [Fact]) {
        let (store, flags) = try await ReportSourcesTests.finished()
        let facts = try ReportSourcesTests.write(store, flags) + (try store.facts(in: mission)
            .filter { !ReportRules.ids.contains($0.rule.id) })
        let words = RedFlagWords(rules: RedFlagEngineTests.rules)
        let walk = [WordedLine(key: "bridge_started", title: "Has work on the Section 3 bridge started?", text: "no")]
        let lines = flags.map { WordedLine(key: $0.rule.id, title: words.title($0), text: words.sentence($0)) }
        let sources = MissionSources.build(SourceInputs(packFiles: try store.packFiles(in: mission), walk: walk,
                                                        flags: lines))
        return (ReportWriter.write(sources: sources, facts: facts, flagged: Self.flaggedNames(flags),
                                   language: language), facts)
    }

    static func flaggedNames(_ flags: [RedFlagResult]) -> Set<String> {
        Set(MissionStore.numbered(flags).filter { $0.flag.outcome == .flag }.map(\.name))
    }

    static func texts(_ lines: [ReportLine], _ section: ReportSection) -> [String] {
        lines.filter { $0.section == section }.map(\.text)
    }

    /// The answer key, written before the code: which sentences, in which section.
    @Test func theKandorReportHasEachSectionInOrder() async throws {
        let lines = try await Self.kandor()

        #expect(lines.map(\.section) == lines.map(\.section).sorted { $0.order < $1.order }, "sections in order")
        #expect(Self.texts(lines, .mission).contains { $0.contains("USD 10,000,000") })
        let project = Self.texts(lines, .project)
        #expect(project.contains("USD 8,500,000 paid to date (the sum of 6 payments)."), "\(project)")
        #expect(project.contains("Section 3 bridge complete: not met, due 30 Sep 2026."), "\(project)")
        #expect(project.filter { $0.contains("risk") || $0.contains("Satisfactory") }
                == ["Overall risk: High (Substantial before)."], "only the overall rating, \(project)")
        #expect(project.contains("Physical progress: 32 of 64 km of asphalt built, as of 30 Sep 2026."), "\(project)")
        let findings = Self.texts(lines, .findings)
        #expect(findings.contains("Red flag MC-01: Payments are 35 points ahead of the work built."), "\(findings)")
        #expect(findings.contains { $0.hasPrefix("Red flag R067:") }, "\(findings)")
        #expect(findings.contains("Your site walk: Has work on the Section 3 bridge started? No."), "\(findings)")
        #expect(!findings.contains { $0.contains("MC-02") }, "a clear flag is not a finding")
        #expect(Self.texts(lines, .agreedActions)
                .contains("Start the Section 3 bridge works: not started, deadline 31 Jul 2026, Contractor."))
    }

    /// Every sentence cites facts of the mission, and passes Ask's check against the sources it was written from.
    @Test func everySentenceCitesFactsAndPassesTheCheck() async throws {
        let (lines, facts) = try await Self.kandorWithFacts()
        let ids = Set(facts.map(\.id))

        #expect(!lines.isEmpty)
        for line in lines {
            #expect(!line.factIds.isEmpty, "\(line.text)")
            #expect(line.factIds.allSatisfy { ids.contains($0) }, "\(line.text)")
            #expect(line.checked, "CHECKFAIL \(line.text) :: \(line.reason ?? "")")
        }
    }

    @Test func theReportIsInTheWalksLanguage() async throws {
        let lines = try await Self.kandor(language: .french)

        #expect(Self.texts(lines, .project).contains("USD 8,500,000 payés à ce jour (somme de 6 paiements)."))
        #expect(ReportSection.project.title(.french) == "Informations sur le projet")
        #expect(ReportSection.allCases.map { $0.title(.english) }
                == ["Mission", "Project information", "Main findings", "Agreed actions since the last mission",
                    "Next steps"])
    }

    /// The debrief's notes: decisions and risks are findings, actions are next steps; the scanned facts too.
    @Test func debriefNotesAndScannedFactsTakeTheirSections() throws {
        let note = { (kind: String, text: String) in
            Fact(id: kind, name: "debrief.\(kind)", value: #"{"byWhen":"","text":"\#(text)","who":""}"#, unit: nil,
                 rule: MissionStore.debriefRule, classification: .officialUseOnly,
                 sources: [FactSource(seq: 3, region: "x")])
        }
        let scan = Fact(id: "s", name: "kmCompleted", value: "32", unit: "km", rule: MissionStore.scanRule,
                        classification: .officialUseOnly, sources: [FactSource(seq: 2, region: "y")])
        let facts = [note("action", "Action, the contractor sends a plan by Friday."),
                     note("risk", "Risk, the rains may delay the works."), scan]
        let sources = MissionSources.build(SourceInputs(facts: facts))

        let lines = ReportWriter.write(sources: sources, facts: facts, flagged: [], language: .english)

        #expect(Self.texts(lines, .nextSteps) == ["From your debrief: Action, the contractor sends a plan by Friday."])
        #expect(Self.texts(lines, .findings).contains("From your debrief: Risk, the rains may delay the works."))
        #expect(Self.texts(lines, .findings).contains("From your scanned invoice: Road built: 32 km."))
        #expect(lines.allSatisfy { $0.checked })
    }

    /// A line with a number or a month its record does not hold fails; a name that sounds like a status does not.
    @Test func aNumberOrMonthNotInTheRecordFails() throws {
        let milestone = try #require(AnswerLinesTests.sources.first { $0.id == AnswerLinesTests.milestone })

        #expect(ReportWriter.numberOrMonth("Section 3 bridge complete: not met, due 30 Sep 2026.", source: milestone)
                == nil)
        #expect(ReportWriter.numberOrMonth("Section 3 bridge complete: not met, due 31 Sep 2026.", source: milestone)
                == "The number 31 is not in the sources it cites.")
        #expect(ReportWriter.numberOrMonth("Section 3 bridge complete: not met, due 30 Oct 2026.", source: milestone)
                == "The month October is not in the sources it cites.")
    }

    /// The walk's check of an agreed action sits with the agreed actions, next to the bank's line.
    @Test func aWalkCheckOfAnActionIsAnAgreedAction() {
        let walk = [WordedLine(key: "action-53f6e638bcf6", title: "Agreed action: Start the Section 3 bridge works",
                               text: "Seen: done.")]
        let fact = Fact(id: "w", name: "walk:action-53f6e638bcf6", value: "seen: done", unit: nil,
                        rule: ReportRules.walkAnswer, classification: .officialUseOnly,
                        sources: [FactSource(seq: 1, region: "action:53f6e638bcf6")])

        let lines = ReportWriter.write(sources: MissionSources.build(SourceInputs(walk: walk)), facts: [fact],
                                       flagged: [], language: .english)

        #expect(lines.map(\.section) == [.agreedActions])
        #expect(lines.first?.text == "Your site walk: Start the Section 3 bridge works, seen done.")
    }

    // MARK: 7.2.3 the officer's sentences

    static let action = "pack:sections/agreed-actions.json#/actions/0"

    /// The Kandor pack's sources and a report fact for the bridge action, named like its source.
    static func officerInputs() -> ([MissionSource], [Fact]) {
        let fact = Fact(id: "a", name: action, value: "", unit: nil, rule: ReportRules.packRecord,
                        classification: .officialUseOnly, sources: [FactSource(seq: 1, region: "x")])
        return (AnswerLinesTests.sources, [fact])
    }

    @Test func theOfficersSentenceIsCheckedAgainstTheFactsTheyPick() {
        let (sources, facts) = Self.officerInputs()
        let write = { (text: String, ids: [String]) in
            ReportWriter.officerLine(section: .findings, text: text, factIds: ids, sources: sources, facts: facts)
        }

        let backed = write("The Section 3 bridge works were not started by the 31 Jul 2026 deadline.", ["a"])
        #expect(backed.checked && backed.reason == nil && backed.factIds == ["a"], "\(backed)")

        let wrongNumber = write("The Section 3 bridge works were not started by 30 Jul 2026.", ["a"])
        #expect(!wrongNumber.checked)
        #expect(wrongNumber.reason == "The number 30 is not in the sources it cites.")

        let opposite = write("The Section 3 bridge works have started.", ["a"])
        #expect(!opposite.checked && opposite.reason == "It says the opposite of the sources it cites.")

        let unproven = write("The road is in good condition.", [])
        #expect(!unproven.checked && unproven.reason == "Pick the facts this sentence comes from.")
        #expect(unproven.factIds.isEmpty)
    }

    /// A sentence the officer writes is never mistaken for the code's: it is checked in full.
    @Test func theOfficersSentenceGetsTheFullCheck() {
        let (sources, facts) = Self.officerInputs()

        let line = ReportWriter.officerLine(section: .findings, text: "The bridge is finished and paid.",
                                            factIds: ["a"], sources: sources, facts: facts)

        #expect(!line.checked)
        #expect(line.reason?.hasPrefix("The word") == true || line.reason?.hasPrefix("It says") == true,
                "\(line.reason ?? "")")
    }
}
