import Foundation
import Observation

/// A mission's site walk on screen (#129): the rules of `SiteWalk`, saved as they change. Every answer
/// and check goes to the encrypted store at once, so a walk opened again (the app closed, the phone
/// locked) comes back as it was. Finishing clears answers to questions that are hidden now, as ODK does,
/// so the finished record holds only what was shown, and then locks the walk.
@MainActor @Observable
final class SiteWalkModel {
    private(set) var walk: SiteWalk
    private(set) var finished: FinishedWalk?
    /// A save that did not happen, in words.
    private(set) var problem: String?
    /// "en" or "fr": the walk's language, switched by the officer.
    var language: String {
        didSet { walk = rebuilt(answers: walk.answers, checks: walk.checks) }
    }

    let mission: String
    private let store: MissionStore
    private let now: () -> Date
    private let timeZone: TimeZone

    static let finishedProblem = "This walk is finished. Its answers cannot change."
    static let saveProblem = "This could not be saved. Try again; if it keeps failing, restart the app."

    init(form: ChecklistForm, actions: AgreedActions, mission: String, store: MissionStore,
         now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current,
         preferred: [String] = Locale.preferredLanguages) throws {
        (self.mission, self.store, self.now, self.timeZone) = (mission, store, now, timeZone)
        let language = SiteWalk.startingLanguage(preferred: preferred, formHasFrench: form.hasFrench)
        self.language = language
        walk = SiteWalk(form: form, actions: actions, answers: try store.answers(form: form.formId, mission: mission),
                        checks: try store.checks(mission: mission), language: language, now: now(), timeZone: timeZone)
        finished = try store.finishedWalk(form: form.formId, mission: mission)
    }

    /// The walk for a mission whose pack is on the phone: its checklist and agreed actions.
    static func load(mission: String, store: MissionStore) throws -> SiteWalkModel {
        let form = try ChecklistForm.read(try store.packFile("forms/road-checklist.json", in: mission))
        let actions = try AgreedActions.read(try store.packFile(AgreedActions.path, in: mission))
        return try SiteWalkModel(form: form, actions: actions, mission: mission, store: store)
    }

    func answer(_ value: String, to question: String) {
        save { try store.saveAnswer(value, to: question, form: walk.form.formId, mission: mission, now: now()) }
    }

    func check(_ seen: ActionSeen, note: String?, action: String) {
        save { try store.saveCheck(seen, note: note, action: action, mission: mission, now: now()) }
    }

    /// Finishes the walk if nothing is missing; says whether it did.
    @discardableResult
    func finish() -> Bool {
        guard walk.canFinish, finished == nil else { return false }
        let shown = Set(walk.questions.map(\.name))
        let hidden = walk.answers.keys.filter { !shown.contains($0) }.sorted()
        return save {
            for question in hidden {
                try store.saveAnswer("", to: question, form: walk.form.formId, mission: mission, now: now())
            }
            try store.finishWalk(form: walk.form.formId, version: walk.form.version, mission: mission, now: now())
        }
    }

    @discardableResult
    private func save(_ change: () throws -> Void) -> Bool {
        defer { reload() }
        do {
            try change()
            problem = nil
            return true
        } catch is MissionStore.WalkFinished {
            problem = Self.finishedProblem
        } catch {
            problem = Self.saveProblem
        }
        return false
    }

    /// The walk as the store holds it now: what was saved is what shows.
    private func reload() {
        let form = walk.form
        guard let answers = try? store.answers(form: form.formId, mission: mission),
              let checks = try? store.checks(mission: mission) else { return }
        walk = rebuilt(answers: answers, checks: checks)
        finished = try? store.finishedWalk(form: form.formId, mission: mission)
    }

    private func rebuilt(answers: [String: String], checks: [String: ActionCheck]) -> SiteWalk {
        SiteWalk(form: walk.form, actions: walk.actions, answers: answers, checks: checks, language: language,
                 now: now(), timeZone: timeZone)
    }
}
