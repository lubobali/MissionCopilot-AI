import Foundation
import Observation

/// The report page's model (#161, step 7.2.4): gathers the mission's facts (report facts written once by
/// #162's `reportFacts`), writes the aide-memoire by code, lets the officer remove, add or edit sentences
/// (checked against the facts they pick), shows each sentence's proof, and saves a draft only when every
/// sentence has proof.
@Observable @MainActor
final class ReportModel {
    enum Stage: Equatable { case loading, ready, cannotOpen }

    private(set) var stage = Stage.loading
    private(set) var lines: [ReportLine] = []
    private(set) var saved: ReportDraft?
    private(set) var approved: ReportApprovalRecord?
    private(set) var problem: String?
    private(set) var walkFinished = false
    private(set) var language = AnswerLanguage.english
    private var sources: [MissionSource] = []
    private var facts: [Fact] = []
    let mission: String
    private let store: MissionStore
    private let signer: any EvidenceSigner
    private let approvalSigner: any ApprovalSigner

    init(mission: String, store: MissionStore,
         signer: any EvidenceSigner = SecureEnclaveEvidenceSigner(user: AppSession.localProfile),
         approvalSigner: any ApprovalSigner = SecureEnclaveApprovalSigner(user: AppSession.localProfile)) {
        (self.mission, self.store, self.signer, self.approvalSigner) = (mission, store, signer, approvalSigner)
    }

    /// The walk and its flags, the report facts, Ask's sources, then the report by code.
    func load() {
        do {
            let walk = try SiteWalkModel.load(mission: mission, store: store)
            let worded = MissionSources.worded(walk)
            let report = try store.reportFacts(in: mission, form: walk.walk.form.formId, flags: walk.flags,
                                               signer: signer)
            let others = try store.facts(in: mission).filter { !ReportRules.ids.contains($0.rule.id) }
            facts = report + others
            sources = MissionSources.build(SourceInputs(packFiles: try store.packFiles(in: mission), facts: others,
                                                        walk: worded.walk, flags: worded.flags))
            language = walk.language == "fr" ? .french : .english
            walkFinished = walk.finished != nil
            let flagged = Set(MissionStore.numbered(walk.flags).filter { $0.flag.outcome == .flag }.map(\.name))
            lines = ReportWriter.write(sources: sources, facts: facts, flagged: flagged, language: language)
            saved = try store.latestDraft(in: mission)
            approved = try store.approval(in: mission)
            if approved != nil, let saved { lines = Self.lines(saved) }  // #163: the approved draft, as signed
            stage = .ready
        } catch {
            stage = .cannotOpen
        }
    }

    var unproven: Int { lines.filter { !$0.checked || $0.factIds.isEmpty }.count }

    var summary: String {
        let count = "\(lines.count) sentence\(lines.count == 1 ? "" : "s")"
        if approved != nil { return "Approved · \(count), each with its proof" }
        return unproven == 0 ? "\(count), each with its proof" : "\(count) · \(unproven) with no proof"
    }

    var canSave: Bool { !lines.isEmpty && unproven == 0 }

    /// #163, 7.3.1: needs proof, draft, ready (exactly the saved draft), approved.
    var state: ReportState { ReportState.of(lines: lines, saved: saved, approved: approved != nil) }

    var canApprove: Bool { state == .ready }

    /// What the page says under Approve (#163, 7.3.4): what to do next, or when it was approved.
    var approvalHint: String {
        switch state {
        case .needsProof: "Fix or remove the sentences with no proof first."
        case .draft: "Save the draft, then approve it."
        case .ready: "Face ID or your passcode signs it on this iPhone."
        case .approved:
            "Approved on this iPhone \(approved?.approvedAt.formatted(date: .abbreviated, time: .shortened) ?? ""). "
                + "It cannot change."
        }
    }

    func remove(_ id: String) {
        guard approved == nil else { return }
        lines.removeAll { $0.id == id }
        problem = nil
    }

    /// Adds the officer's sentence at the end of its section, checked; returns whether it has proof.
    @discardableResult
    func add(section: ReportSection, text: String, factIds: [String]) -> Bool {
        guard approved == nil else { return false }
        let line = ReportWriter.officerLine(section: section, text: text, factIds: factIds, sources: sources,
                                            facts: facts)
        guard !line.text.isEmpty else { return false }
        let last = lines.lastIndex { $0.section.order <= section.order }
        lines.insert(line, at: last.map { $0 + 1 } ?? 0)
        return line.checked
    }

    /// Replaces a sentence with the officer's words, checked against the facts they pick.
    @discardableResult
    func edit(_ id: String, text: String, factIds: [String]) -> Bool {
        guard approved == nil, let index = lines.firstIndex(where: { $0.id == id }) else { return false }
        let line = ReportWriter.officerLine(section: lines[index].section, text: text, factIds: factIds,
                                            sources: sources, facts: facts)
        lines[index] = line
        return line.checked
    }

    /// The facts the officer can pick, in words.
    var pickable: [(id: String, words: String)] {
        facts.compactMap { fact in source(of: fact).map { (fact.id, AnswerLines.line($0, language: language).text) } }
    }

    /// What a sentence stands on: each fact's source as a card.
    func proof(_ line: ReportLine) -> [SourceCardWords] {
        line.factIds.compactMap { id in facts.first { $0.id == id }.flatMap(source).map(SourceWords.card) }
    }

    func save() {
        guard approved == nil else { return }
        guard canSave else {
            problem = "Remove or fix the sentences with no proof before saving."
            return
        }
        do {
            saved = try store.saveDraft(lines, language: language, in: mission)
            problem = nil
        } catch {
            problem = "The draft could not be saved. Try again."
        }
    }

    /// #163: asks Face ID or the passcode once and stores the signed approval of the saved draft. A cancel or a
    /// failure leaves the report as it was and says so.
    func approve() async {
        guard approved == nil else { return }
        guard state == .ready, let draft = saved else {
            problem = "Save the draft first, then approve it."
            return
        }
        let now = Date()
        do {
            let signed = try await ReportApproval.sign(draft: draft, mission: mission, by: AppSession.localProfile,
                                                       at: now, signer: approvalSigner)
            approved = try store.approve(signed, draft: draft, by: AppSession.localProfile, at: now, in: mission)
            problem = nil
        } catch ReportApproval.Failure.cancelled {
            problem = "Not approved: you cancelled."
        } catch ReportApproval.Failure.failed {
            problem = "Not approved: Face ID or the passcode did not work. Try again."
        } catch {
            problem = "Not approved: the approval could not be stored. Try again."
        }
    }

    /// A stored draft's sentences as lines (only proven lines are ever stored).
    private static func lines(_ draft: ReportDraft) -> [ReportLine] {
        draft.sentences.map { sentence in
            ReportLine(section: ReportSection(rawValue: sentence.section) ?? .findings, text: sentence.text,
                       factIds: sentence.factIds, checked: true)
        }
    }

    private func source(of fact: Fact) -> MissionSource? {
        sources.first { $0.id == fact.name || $0.id == "fact:\(fact.id)" }
    }
}
