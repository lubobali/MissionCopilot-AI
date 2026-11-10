import Foundation

/// The rules behind report facts (#162): PROV Activities written by code from the report's sources.
enum ReportRules {
    static let packRecord = RuleRef(id: "pack-record", version: "1")
    static let walkAnswer = RuleRef(id: "walk-answer", version: "1")
    static let redFlag = RuleRef(id: "red-flag", version: "1")
    static let ids: Set = [packRecord.id, walkAnswer.id, redFlag.id]
}

/// Facts written by code from the report's sources (#162, decided A), so every report sentence keeps ADR
/// 0009's one path (sentence -> facts -> evidence): the bank records a report uses (citing the pack's evidence,
/// the file and pointer), the finished walk's answers and checks (citing the walk's evidence), and the red flags
/// (citing their inputs). Written once: asking again adds nothing.
extension MissionStore {
    /// The mission's report facts, written first if they are not yet.
    @discardableResult
    func reportFacts(in mission: String, form: String, flags: [RedFlagResult], signer: any EvidenceSigner,
                     now: Date = Date()) throws -> [Fact] {
        let pack = try packEvidence(in: mission, signer: signer, now: now)
        let walk = try finishedWalk(form: form, mission: mission) == nil
            ? nil : try walkEvidence(form: form, in: mission, signer: signer, now: now)
        let known = try facts(in: mission)
        let inputs = try packRecords(in: mission, seq: pack) + (try walk.map { try walkAnswers(in: mission, form: form,
                                                                                               seq: $0) } ?? [])
            + Self.numbered(flags).compactMap { flagFact($0.flag, name: $0.name, pack: pack, known: known) }
        let written = Set(known.filter { ReportRules.ids.contains($0.rule.id) }.map(Self.key))
        let fresh = inputs.filter { !written.contains(Self.key($0)) }
        if !fresh.isEmpty { try addFacts(fresh, to: mission, now: now) }
        return try facts(in: mission).filter { ReportRules.ids.contains($0.rule.id) }
    }

    /// The bank records a report uses: the contract, each payment and the paid total, the milestones, the agreed
    /// actions, the ratings and the physical progress; each with its file's SHA-256.
    private func packRecords(in mission: String, seq: Int) throws -> [FactInput] {
        let files = try packFiles(in: mission)
        let hashes = Dictionary(uniqueKeysWithValues: (try storedPack(for: mission)?.files ?? []).map {
            ($0.path, $0.sha256)
        })
        return MissionSources.build(SourceInputs(packFiles: files)).filter { source in
            source.kind == .pack && Self.reportRecords.contains {
                source.id.range(of: $0, options: .regularExpression) != nil
            }
        }.map { source in
            let place = String(source.id.dropFirst("pack:".count))
            let path = place.components(separatedBy: "#").first ?? place
            let region = place.hasSuffix("#paid")
                ? place.replacingOccurrences(of: "#paid", with: " sum") : place
            return FactInput(name: source.id, value: source.text, unit: nil,
                             sources: [FactSource(seq: seq, region: "\(region) sha256:\(hashes[path] ?? "")")],
                             rule: ReportRules.packRecord)
        }
    }

    private static let reportRecords = [#"#/contracts/\d+$"#, #"/payments/\d+$"#, "#paid$", #"#/milestones/\d+$"#,
                                        #"#/actions/\d+$"#, #"ratings\.json#/"#, "physicalProgress$"]

    /// Each answer and agreed-action check of the finished walk, with its photo's evidence when it has one.
    private func walkAnswers(in mission: String, form: String, seq: Int) throws -> [FactInput] {
        let answers = try answers(form: form, mission: mission).sorted { $0.key < $1.key }.map { question, value in
            // #193: a photo answer ("evidence:N") cites its photo too, so the photo goes with the report
            let photo = Int(value.hasPrefix("evidence:") ? value.dropFirst("evidence:".count) : "")
                .map { [FactSource(seq: $0, region: nil)] } ?? []
            return FactInput(name: "walk:\(question)", value: value, unit: nil,
                             sources: [FactSource(seq: seq, region: "question:\(question)")] + photo,
                             rule: ReportRules.walkAnswer)
        }
        let checks = try checks(mission: mission).sorted { $0.key < $1.key }.map { action, check in
            let words = ["seen: \(check.seen.rawValue)", check.note.map { "note: \($0)" }].compactMap { $0 }
            let photo = check.photo.map { [FactSource(seq: $0, region: nil)] } ?? []
            // Named like Ask's source for it (#161: the report reuses Ask's checked wording).
            return FactInput(name: "walk:action-\(action.prefix(12))", value: words.joined(separator: "; "), unit: nil,
                             sources: [FactSource(seq: seq, region: "action:\(action)")] + photo,
                             rule: ReportRules.walkAnswer)
        }
        return answers + checks
    }

    /// A red flag with inputs, citing them: a pack field through the pack's evidence, a photo, or a confirmed
    /// fact's own sources; strictly confidential like the stored flags. A flag with no input makes no fact.
    /// Each flag named like Ask's source for it: its rule and its place among that rule's results.
    static func numbered(_ flags: [RedFlagResult]) -> [(flag: RedFlagResult, name: String)] {
        var seen: [String: Int] = [:]
        return flags.map { flag in
            let count = seen[flag.rule.id, default: 0]
            seen[flag.rule.id] = count + 1
            return (flag, "flag:\(flag.rule.id):\(count)")
        }
    }

    private func flagFact(_ flag: RedFlagResult, name: String, pack: Int, known: [Fact]) -> FactInput? {
        let byId = Dictionary(uniqueKeysWithValues: known.map { ($0.id, $0) })
        var sources: [FactSource] = []
        for input in flag.inputs {
            switch input {
            case .pack(let citation):
                sources.append(FactSource(seq: pack, region: "\(citation.path)#\(citation.pointer) "
                                              + "sha256:\(citation.sha256)"))
            case .evidence(let photo):
                sources.append(FactSource(seq: photo.seq, region: nil))
            case .fact(let ref):
                sources += byId[ref.id]?.sources ?? []
            }
        }
        guard !sources.isEmpty else { return nil }
        // A fact cites each evidence item once (fact_source's key): the fields of one item go in one region.
        var merged: [FactSource] = []
        for source in sources {
            if let index = merged.firstIndex(where: { $0.seq == source.seq }) {
                let regions = [merged[index].region, source.region].compactMap { $0 }
                let region = regions.isEmpty ? nil : regions.joined(separator: " | ")
                merged[index] = FactSource(seq: source.seq, region: region)
            } else {
                merged.append(source)
            }
        }
        sources = merged
        let outcome = switch flag.outcome {
        case .flag: "flag"
        case .clear: "clear"
        case .notChecked(let why): "notChecked \(why.rawValue)"
        }
        let computed = flag.computed.map { " computed \($0)" } ?? ""
        return FactInput(name: name, value: outcome + computed, unit: nil,
                         sources: sources, rule: ReportRules.redFlag, floor: .strictlyConfidential)
    }

    private static func key(_ fact: Fact) -> String { "\(fact.rule.id) \(fact.name) \(fact.sources[0].seq)" }
    private static func key(_ input: FactInput) -> String {
        "\(input.rule.id) \(input.name) \(input.sources[0].seq)"
    }
}
