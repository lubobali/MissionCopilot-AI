import Foundation
import Observation
import UIKit

/// A mission's site walk on screen (#129): the rules of `SiteWalk`, saved as they change. Every answer
/// and check goes to the encrypted store at once, so a walk opened again (the app closed, the phone
/// locked) comes back as it was. Finishing clears answers to questions that are hidden now, as ODK does,
/// so the finished record holds only what was shown, and then locks the walk.
@MainActor @Observable
final class SiteWalkModel {
    private(set) var walk: SiteWalk
    private(set) var finished: FinishedWalk?
    /// The red flags (#134): live while the walk is open, then the ones stored at the finish.
    private(set) var flags: [RedFlagResult] = []
    /// A save that did not happen, in words.
    var problem: String?
    /// "en" or "fr": the walk's language, switched by the officer.
    var language: String {
        didSet { walk = rebuilt(answers: walk.answers, checks: walk.checks) }
    }

    let mission: String
    let store: MissionStore
    let now: () -> Date
    private let timeZone: TimeZone
    private let figures: RedFlagInputs
    private let rules: RedFlagRules
    let places: any PlaceFinder
    /// Signs photos into the mission's evidence chain: the chip key the phone was connected with.
    let signer: any EvidenceSigner
    /// The place being read since the camera opened, ready by the shutter (#129).
    var pendingPlace: Task<PlaceReading, Never>?
    /// Thumbnails already opened from their sealed files, so scrolling does not open them again.
    @ObservationIgnored var thumbnails: [Int: UIImage] = [:]

    static let finishedProblem = "This walk is finished. Its answers cannot change."
    static let saveProblem = "This could not be saved. Try again; if it keeps failing, restart the app."
    var finishedProblem: String {
        language == "fr" ? "Cette visite est terminée. Ses réponses ne peuvent plus changer." : Self.finishedProblem
    }
    var saveProblem: String {
        language == "fr" ? "L'enregistrement a échoué. Réessayez ; si cela continue, redémarrez l'application."
                         : Self.saveProblem
    }

    init(form: ChecklistForm, actions: AgreedActions, mission: String, store: MissionStore,
         now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current,
         preferred: [String] = Locale.preferredLanguages, places: any PlaceFinder = ApplePlaceFinder(),
         signer: any EvidenceSigner = SecureEnclaveEvidenceSigner(user: AppSession.localProfile),
         figures: RedFlagInputs = RedFlagInputs(), rules: RedFlagRules = (try? .bundled()) ?? .empty) throws {
        (self.mission, self.store, self.now, self.timeZone, self.places) = (mission, store, now, timeZone, places)
        (self.signer, self.figures, self.rules) = (signer, figures, rules)
        let language = SiteWalk.startingLanguage(preferred: preferred, formHasFrench: form.hasFrench)
        self.language = language
        walk = SiteWalk(form: form, actions: actions, answers: try store.answers(form: form.formId, mission: mission),
                        checks: try store.checks(mission: mission), language: language, now: now(), timeZone: timeZone)
        finished = try store.finishedWalk(form: form.formId, mission: mission)
        flags = currentFlags()
    }

    /// The walk for a mission whose pack is on the phone: its checklist and agreed actions. Files already
    /// opened (Ask, #150) are used as they are instead of unwrapping the mission key again for each.
    static func load(mission: String, store: MissionStore, files: [String: Data] = [:]) throws -> SiteWalkModel {
        let file = { (path: String) throws -> Data in
            if let opened = files[path] { return opened }
            return try store.packFile(path, in: mission)
        }
        let form = try ChecklistForm.read(try file("forms/road-checklist.json"))
        let actions = try AgreedActions.read(try file(AgreedActions.path))
        // A pack without a section leaves that input empty: its rules say "not checked", never clear.
        let figures = RedFlagInputs(contracts: try? PackContracts.read(try file(PackContracts.path)),
                                    milestones: try? PackMilestones.read(try file(PackMilestones.path)))
        return try SiteWalkModel(form: form, actions: actions, mission: mission, store: store, figures: figures)
    }

    func answer(_ value: String, to question: String) {
        save { try store.saveAnswer(value, to: question, form: walk.form.formId, mission: mission, now: now()) }
    }

    /// What was seen and a note; the action's photo, if any, stays with it.
    func check(_ seen: ActionSeen, note: String?, action: String) {
        let photo = walk.checks[action]?.photo
        save { try store.saveCheck(seen, note: note, photo: photo, action: action, mission: mission, now: now()) }
    }

    /// Records where the phone is as a geopoint answer. Location is asked for only here, when the officer
    /// taps (MASVS-PRIVACY-1); a refusal or no fix saves nothing and says what to do.
    func recordPlace(for question: String) async {
        let reading = await places.onePlace()
        guard case .place(let place) = reading else {
            problem = reading.problem(app: Self.appName, language: language)
            return
        }
        answer(place.geopoint, to: question)
    }

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Mission Copilot"
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
            try store.finishWalk(form: walk.form.formId, version: walk.form.version, mission: mission, now: now(),
                                 flags: liveFlags())
        }
    }

    @discardableResult
    func save(_ change: () throws -> Void) -> Bool {
        defer { reload() }
        do {
            try change()
            problem = nil
            return true
        } catch is MissionStore.WalkFinished {
            problem = finishedProblem
        } catch {
            problem = saveProblem
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
        flags = currentFlags()
    }

    /// The flags as they are now: the pack's figures, this phone's photos and the confirmed scanned invoices,
    /// through the rules file.
    private func liveFlags() -> [RedFlagResult] {
        var inputs = figures
        inputs.photos = try? store.photoReuse(for: mission)
        inputs.scanned = (try? store.facts(in: mission)).map(ScannedInvoice.all)  // #138: confirmed scans
        return RedFlagEngine(rules: rules).run(inputs, walk: now(), timeZone: timeZone)
    }

    /// After the finish: the stored flags, then the results of invoices confirmed from documents scanned
    /// later (found on the iPhone, #138: a scan is allowed after the finish). The stored ones never change.
    private func currentFlags() -> [RedFlagResult] {
        guard let stored = try? store.storedFlags(mission: mission) else { return liveFlags() }
        let scanned = liveFlags().filter { result in
            result.inputs.contains { input in if case .fact = input { true } else { false } }
        }
        return stored + scanned.filter { !stored.contains($0) }
    }

    private func rebuilt(answers: [String: String], checks: [String: ActionCheck]) -> SiteWalk {
        SiteWalk(form: walk.form, actions: walk.actions, answers: answers, checks: checks, language: language,
                 now: now(), timeZone: timeZone)
    }
}
