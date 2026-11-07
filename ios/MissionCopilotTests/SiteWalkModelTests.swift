import Foundation
import Testing
@testable import MissionCopilot

/// The site walk saved as it goes (#129, step 6.2.3): every answer and check is in the encrypted store at
/// once, a walk opened again comes back as it was, and finishing clears hidden answers, then locks.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SiteWalkModelTests {
    let mission = "kandor-roads"

    private func store() throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        return store
    }

    private func model(_ store: MissionStore, preferred: [String] = ["en-US"]) throws -> SiteWalkModel {
        let (form, actions) = try SiteWalkTests.kandor()
        return try SiteWalkModel(form: form, actions: actions, mission: mission, store: store,
                                 now: { SiteWalkTests.walkDay }, timeZone: .gmt, preferred: preferred)
    }

    private func fill(_ model: SiteWalkModel) throws {
        let (answers, checks) = try SiteWalkTests.complete()
        for (question, value) in answers { model.answer(value, to: question) }
        for (action, check) in checks { model.check(check.seen, note: check.note, action: action) }
    }

    @Test func theWalkLoadsFromTheImportedPack() async throws {
        let rig = try PackDownloaderTests.Rig()
        guard case .verified(let ready) = await rig.run() else { throw CancellationError() }
        let store = try MissionStore(store: EncryptedStore.open(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite"),
            key: DataKey.random()), vault: SoftwareKeyVault())
        _ = try PackImport.run(ready, title: "Kandor Rural Roads Project, Package 1", into: store,
                               schema: PackSectionsTests.schema())

        let model = try SiteWalkModel.load(mission: PackDownloaderTests.mission, store: store)

        #expect(model.walk.form.formId == "kandor_road_check")
        #expect(model.walk.actions.actions.count == 3)
        #expect(model.walk.progress.answered == 0)
    }

    @Test func everyAnswerAndCheckIsSavedAtOnceAndComesBackWhenOpenedAgain() throws {
        let store = try store()
        let first = try model(store)
        let action = first.walk.actions.actions[0].key

        first.answer("6.2", to: "road_width_m")
        first.check(.notStarted, note: "No works at the bridge site", action: action)
        let again = try model(store)

        #expect(again.walk.answers["road_width_m"] == "6.2")
        #expect(again.walk.checks[action] == ActionCheck(seen: .notStarted, note: "No works at the bridge site"))
    }

    @Test func finishingClearsHiddenAnswersThenLocksTheWalk() throws {
        // As ODK does: the finished record holds only what was shown.
        let store = try store()
        let model = try model(store)
        model.answer("yes", to: "bridge_started")
        model.answer("3", to: "piers_built")
        try fill(model)  // bridge_started becomes "no": the bridge questions hide

        #expect(model.finish())

        #expect(model.finished != nil)
        #expect(try store.answers(form: "kandor_road_check", mission: mission)["piers_built"] == nil)
        #expect(try store.finishedWalk(form: "kandor_road_check", mission: mission)?.version == "2026110401")
    }

    @Test func aWalkWithSomethingMissingDoesNotFinish() throws {
        let store = try store()
        let model = try model(store)
        model.answer("6.2", to: "road_width_m")

        #expect(!model.finish())

        #expect(model.finished == nil)
        #expect(try store.finishedWalk(form: "kandor_road_check", mission: mission) == nil)
    }

    @Test func afterTheFinishAnAnswerCannotChangeAndTheWalkSaysWhy() throws {
        let store = try store()
        let walk = try model(store)
        try fill(walk)
        #expect(walk.finish())

        walk.answer("7.0", to: "road_width_m")

        #expect(walk.walk.answers["road_width_m"] == "6.2")
        #expect(walk.problem == "This walk is finished. Its answers cannot change.")
        #expect(try model(store).finished != nil, "a finished walk opens finished")
    }

    @Test func theWalkStartsInFrenchOnAFrenchPhoneAndTheOfficerCanSwitch() throws {
        let store = try store()
        let model = try model(store, preferred: ["fr-FR"])
        model.answer("25", to: "road_width_m")

        #expect(model.language == "fr")
        #expect(model.walk.problem(of: "road_width_m") == "Une largeur de route est comprise entre 0 et 20 mètres")
        model.language = "en"
        #expect(model.walk.problem(of: "road_width_m") == "A road width is between 0 and 20 metres")
    }

    /// Found on the iPhone (#138): documents may be scanned after the walk is finished, so the facts confirmed
    /// then add their red flags next to the stored ones, which never change.
    @Test func factsConfirmedAfterTheFinishAddTheirFlagsToTheStoredOnes() throws {
        let store = try store()
        let walk = try model(store)
        try fill(walk)
        #expect(walk.finish())
        let stored = try #require(try store.storedFlags(mission: mission))
        let scan = try store.addScan([try ScanStoreTests.page()], to: mission, signer: SoftwareEvidenceSigner())
        let typed = ["14", "2026-10-12", "480000", "8500000", "10000000", "32", "64", "not_started"]
        let decisions = Dictionary(uniqueKeysWithValues: zip(InvoiceFacts.fields, typed.map(FactDecision.correct)))
        try store.confirmFacts(FactReview(facts: .blank, printedAt: [:], problems: []), decisions: decisions,
                               pages: scan.pages, in: mission)

        let flags = try model(store).flags

        #expect(Array(flags.prefix(stored.count)) == stored)
        #expect(flags.dropFirst(stored.count).map(\.subject) == ["Scanned invoice 14", "Scanned invoice 14"])
        #expect(flags.dropFirst(stored.count).map(\.outcome) == [.clear, .flag])
        #expect(try store.storedFlags(mission: mission) == stored)
    }
}
