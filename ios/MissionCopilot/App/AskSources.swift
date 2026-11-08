import Foundation

/// Gathers the mission's sources from the encrypted store (#145, step 6.7.1): every file of the signed pack,
/// the confirmed facts and notes, and (when the pack has its walk) the walk's answers, the agreed actions'
/// checks and the red flags, each in the officer's words. Opened in memory only.
extension MissionSources {
    @MainActor
    static func load(mission: String, store: MissionStore) -> [MissionSource] {
        var inputs = SourceInputs()
        if let pack = try? store.storedPack(for: mission) {
            for file in pack.files {
                inputs.packFiles[file.path] = try? store.packFile(file.path, in: mission)
            }
        }
        inputs.facts = (try? store.facts(in: mission)) ?? []
        if let walk = try? SiteWalkModel.load(mission: mission, store: store) {
            (inputs.walk, inputs.flags) = worded(walk)
        }
        return build(inputs)
    }

    /// The walk's answers with their questions, each agreed action's check, and the red flags' sentences.
    @MainActor
    static func worded(_ model: SiteWalkModel) -> (walk: [WordedLine], flags: [WordedLine]) {
        let walk = model.walk
        let answers = walk.form.questions.compactMap { question in
            walk.answers[question.name].map { WordedLine(key: question.name, title: question.label.english, text: $0) }
        }
        let checks = walk.actions.actions.compactMap { action in
            walk.checks[action.key].map { check in
                WordedLine(key: "action-\(action.key.prefix(12))", title: "Agreed action: \(action.action)",
                           text: "Seen: \(Self.seen(check.seen))." + (check.note.map { " Note: \($0)" } ?? ""))
            }
        }
        let words = RedFlagWords(rules: (try? .bundled()) ?? .empty)
        let flags = model.flags.map { WordedLine(key: $0.rule.id, title: words.title($0), text: words.sentence($0)) }
        return (answers + checks, flags)
    }

    static func seen(_ seen: ActionSeen) -> String {
        switch seen {
        case .done: "done"
        case .inProgress: "in progress"
        case .notStarted: "not started"
        case .couldNotCheck: "could not check"
        }
    }
}
