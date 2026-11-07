import Foundation
import GRDB
import Testing
import UIKit
@testable import MissionCopilot

/// The red flags as they stood at the end of the walk (#134, step 6.3.5): stored with the finish in one
/// transaction, sealed with the mission key, Strictly Confidential, append-only. The database refuses any
/// later change, they go only with their mission, and the audit log names a raised rule, never a value.
struct RedFlagStoreTests {
    static let form = SiteWalkStoreTests.form
    let mission = "kandor-roads"

    private func store() throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        return store
    }

    /// The Kandor results plus an MC-04 flag citing two photos and a skipped mission.
    static func kandorFlags() throws -> [RedFlagResult] {
        let contracts = try PackContracts.read(try PackFiguresTests.file(PackContracts.path))
        let milestones = try PackMilestones.read(try PackFiguresTests.file(PackMilestones.path))
        var results = RedFlagEngineTests.run(contracts: contracts, milestones: milestones)
        let photos = PhotoReuseCheck(photos: [PhotoRef(mission: "kandor-roads", seq: 1)],
                                     sameBytes: ["h": [PhotoRef(mission: "kandor-roads", seq: 1),
                                                       PhotoRef(mission: "other-site", seq: 3)]],
                                     skipped: ["old"])
        results.removeLast()
        results += RedFlagEngineTests.only("MC-04", RedFlagEngine(rules: RedFlagEngineTests.rules)
            .run(RedFlagInputs(photos: photos), walk: SiteWalkTests.walkDay, timeZone: .gmt))
        return results
    }

    private func finish(_ store: MissionStore, flags: [RedFlagResult]) throws {
        try store.finishWalk(form: Self.form, version: "2026110401", mission: mission, flags: flags)
    }

    @Test func theFlagsAtTheFinishReadBackExactly() throws {
        let store = try store()
        let flags = try Self.kandorFlags()

        try finish(store, flags: flags)

        #expect(try store.storedFlags(mission: mission) == flags)
        // Typed: Xcode 26.6 (CI) could not type-check the short form in time.
        let raised = flags.filter { (result: RedFlagResult) -> Bool in result.outcome == .flag }
        #expect(raised.count == 3)
        #expect(flags.last?.skippedMissions == 1)
    }

    @Test func beforeTheFinishNothingIsStored() throws {
        let store = try store()

        #expect(try store.storedFlags(mission: mission) == nil)
    }

    @Test func theyAreSealedAndStrictlyConfidential() throws {
        let store = try store()
        try finish(store, flags: try Self.kandorFlags())

        let rows = try store.store.read { database in
            try Row.fetchAll(database, sql: "SELECT rule_id, outcome, classification, sealed_detail FROM red_flag")
        }

        #expect(rows.count == 6)
        #expect(rows.allSatisfy { ($0["classification"] as String) == "strictly_confidential" })
        #expect(rows.map { $0["outcome"] as String } == ["clear", "flag", "flag", "clear", "notChecked", "flag"])
        for row in rows {
            let sealed: Data = row["sealed_detail"]
            #expect(!sealed.contains(Data("ocds-kandor".utf8)) && !sealed.contains(Data("contracts.json".utf8)))
        }
    }

    @Test func theAuditLogNamesEachRaisedRuleNeverAValue() throws {
        let store = try store()
        try finish(store, flags: try Self.kandorFlags())

        let events = try store.store.auditEvents().filter { $0.action == .redFlagRaised }

        #expect(events.map(\.target) == ["R067", "MC-01", "MC-04"])
        #expect(try store.store.verifyAudit() == .valid(count: try store.store.auditEvents().count))
    }

    @Test(arguments: [
        "UPDATE red_flag SET outcome = 'clear'",
        "DELETE FROM red_flag",
        "INSERT INTO red_flag VALUES ('kandor-roads', 99, 'MC-09', '1', 'clear', x'00', 'strictly_confidential', 0)"
    ])
    func theDatabaseItselfRefusesChangesAfterTheFinish(sql: String) throws {
        let store = try store()
        try finish(store, flags: try Self.kandorFlags())

        #expect(throws: DatabaseError.self) { try store.store.rawExecuteForTests(sql) }
        #expect(try store.storedFlags(mission: mission)?.count == 6)
    }

    @Test func aSecondFinishAddsNoFlags() throws {
        let store = try store()
        try finish(store, flags: try Self.kandorFlags())

        #expect(throws: MissionStore.WalkFinished.self) { try finish(store, flags: try Self.kandorFlags()) }
        #expect(try store.storedFlags(mission: mission)?.count == 6)
    }

    @Test func theyGoWithTheMissionAndItsNextLifeStartsClean() throws {
        let store = try store()
        try finish(store, flags: try Self.kandorFlags())

        try store.reprovision(mission, at: Date())
        try store.create(mission: mission, title: "Kandor rural roads")

        #expect(try store.storedFlags(mission: mission) == nil)
        #expect(try store.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM red_flag") } == 0)
    }

    @Test func aWalkFinishedBeforeRedFlagsExistedHasNoneStoredNotLiveOnes() throws {
        // A phone that finished its walk with the last build: the walk is locked, no flags were stored, and
        // none are made up now.
        let store = try store()
        try store.finishWalk(form: Self.form, version: "2026110401", mission: mission)

        #expect(try store.storedFlags(mission: mission) == [])
    }

    @Test func aStoreFromTheLastBuildGainsTheRedFlagTable() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let key = try DataKey.random()
        _ = try EncryptedStore.open(at: file, key: key, upTo: "v12-action-photo")

        let upgraded = try EncryptedStore.open(at: file, key: key)

        #expect(try upgraded.appliedMigrations().contains("v13-red-flags"))
    }
}

/// Live during the walk, then frozen (#134, step 6.3.5): the walk shows the flags as they are now (a new
/// photo changes MC-04 at once); Finish stores exactly those, and after it the walk shows the stored ones.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RedFlagWalkTests {
    let mission = "kandor-roads"

    private func walk() throws -> (SiteWalkModel, MissionStore) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        try store.create(mission: "other-site", title: "Other site")
        let (form, actions) = try SiteWalkTests.kandor()
        let figures = RedFlagInputs(
            contracts: try PackContracts.read(try PackFiguresTests.file(PackContracts.path)),
            milestones: try PackMilestones.read(try PackFiguresTests.file(PackMilestones.path)))
        let walk = try SiteWalkModel(form: form, actions: actions, mission: mission, store: store,
                                     now: { SiteWalkTests.walkDay }, timeZone: .gmt, preferred: ["en-US"],
                                     places: PlaceTests.FakePlaces(.place(PlaceTests.kmEighteen)),
                                     signer: SoftwareEvidenceSigner(), figures: figures)
        return (walk, store)
    }

    private func photo() throws -> UIImage {
        try #require(UIImage(data: try SitePhotoTests.cameraJPEG(width: 600, height: 400)))
    }

    @Test func theWalkOpensWithTheKandorFlags() throws {
        let (walk, _) = try walk()

        #expect(walk.flags.map(\.rule.id) == ["R068", "R067", "MC-01", "MC-02", "MC-03", "MC-04"])
        let raised: [String] = walk.flags.filter { (result: RedFlagResult) -> Bool in result.outcome == .flag }
            .map { (result: RedFlagResult) -> String in result.rule.id }
        #expect(raised == ["R067", "MC-01"])
    }

    @Test func aPhotoChangesThePhotoRuleAtOnce() async throws {
        let (walk, _) = try walk()
        #expect(walk.flags.last?.outcome == .notChecked(.needsPhotos))

        _ = try #require(await walk.photoTaken(try photo(), for: .question("sample_photo")))

        #expect(walk.flags.last?.outcome == .clear)
    }

    @Test func finishStoresExactlyWhatTheWalkShowedAndThenItIsFrozen() async throws {
        let (walk, store) = try walk()
        let (answers, checks) = try SiteWalkTests.complete()
        for (question, value) in answers { walk.answer(value, to: question) }
        for (key, check) in checks { walk.check(check.seen, note: nil, action: key) }
        let seq = try #require(await walk.photoTaken(try photo(), for: .question("sample_photo")))
        let shown = walk.flags
        #expect(shown.last?.outcome == .clear)

        #expect(walk.finish())

        #expect(try store.storedFlags(mission: mission) == shown)
        // The very same photo copied elsewhere after the finish: live, MC-04 would now flag; the walk keeps
        // showing what was stored.
        let capture = Capture(file: try store.evidenceFile(in: mission, seq: seq), kind: .photo,
                              capturedAt: SiteWalkTests.walkDay, clockSource: .device, location: nil)
        try store.addEvidence(capture, to: "other-site", signer: SoftwareEvidenceSigner())
        #expect(try store.photoReuse(for: mission).sameBytes.values.contains { $0.count == 2 })
        walk.answer("x", to: "board_ref")  // any reload
        #expect(walk.flags == shown)
    }
}
