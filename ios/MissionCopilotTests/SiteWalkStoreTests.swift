import Foundation
import GRDB
import Testing
@testable import MissionCopilot

/// The site walk's records (#129, step 6.2.1): checklist answers and agreed-action checks, sealed with
/// the mission key and changeable until the walk is finished; then the database itself refuses any
/// change. They go only with their whole mission, so a mission's next life starts clean (#94).
struct SiteWalkStoreTests {
    static let form = "kandor_road_check"
    let mission = "kandor-roads"
    let bridgeAction = String(repeating: "a", count: 64)

    private func store() throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        return store
    }

    @Test func anAnswerReadsBackAndIsStoredSealed() throws {
        let store = try store()

        try store.saveAnswer("6.2", to: "road_width_m", form: Self.form, mission: mission)

        #expect(try store.answers(form: Self.form, mission: mission) == ["road_width_m": "6.2"])
        let sealed = try store.store.read { try Data.fetchAll($0, sql: "SELECT sealed_value FROM site_answer") }
        #expect(sealed.count == 1)
        #expect(!sealed[0].contains(Data("6.2".utf8)))
    }

    @Test func aNewAnswerReplacesTheOldOneAndAnEmptyOneClearsIt() throws {
        let store = try store()
        try store.saveAnswer("6.2", to: "road_width_m", form: Self.form, mission: mission)

        try store.saveAnswer("6.4", to: "road_width_m", form: Self.form, mission: mission)
        #expect(try store.answers(form: Self.form, mission: mission) == ["road_width_m": "6.4"])

        try store.saveAnswer("", to: "road_width_m", form: Self.form, mission: mission)
        #expect(try store.answers(form: Self.form, mission: mission).isEmpty)
    }

    @Test func answersBelongToTheirFormAndMission() throws {
        let store = try store()
        try store.create(mission: "kandor-bridges", title: "Kandor bridges")
        try store.saveAnswer("yes", to: "bridge_started", form: Self.form, mission: mission)

        #expect(try store.answers(form: "another_form", mission: mission).isEmpty)
        #expect(try store.answers(form: Self.form, mission: "kandor-bridges").isEmpty)
    }

    @Test func anActionCheckReadsBackWithItsNoteAndCanBeChangedBeforeTheEnd() throws {
        let store = try store()

        try store.saveCheck(.notStarted, note: "No works at the bridge site", action: bridgeAction, mission: mission)
        try store.saveCheck(.inProgress, note: nil, action: bridgeAction, mission: mission)

        #expect(try store.checks(mission: mission) == [bridgeAction: ActionCheck(seen: .inProgress, note: nil)])
    }

    @Test func anActionCheckCanPointAtItsPhoto() throws {
        // #129 PR 2 (schema v12): the photo is evidence; the check keeps its seq.
        let store = try store()
        try store.addEvidence(EvidenceChainTests.capture("bridge site"), to: mission, signer: SoftwareEvidenceSigner())

        try store.saveCheck(.notStarted, note: "No works", photo: 1, action: bridgeAction, mission: mission)

        #expect(try store.checks(mission: mission)[bridgeAction] == ActionCheck(seen: .notStarted, note: "No works",
                                                                                 photo: 1))
    }

    @Test func aCheckCannotPointAtEvidenceThatIsNotThere() throws {
        let store = try store()

        #expect(throws: MissionStore.NoSuchPhoto.self) {
            try store.saveCheck(.done, note: nil, photo: 7, action: self.bridgeAction, mission: self.mission)
        }
    }

    @Test func finishingRecordsTheFormVersionAndLocksTheWalk() throws {
        let store = try store()
        try store.saveAnswer("yes", to: "bridge_started", form: Self.form, mission: mission)
        try store.saveCheck(.done, note: nil, action: bridgeAction, mission: mission)

        let finished = Date(timeIntervalSince1970: 100)
        try store.finishWalk(form: Self.form, version: "2026110401", mission: mission, now: finished)

        #expect(try store.finishedWalk(form: Self.form, mission: mission)
                == FinishedWalk(version: "2026110401", finishedAt: finished))
        let form = Self.form, mission = self.mission, action = bridgeAction
        let refused = MissionStore.WalkFinished.self
        #expect(throws: refused) { try store.saveAnswer("no", to: "bridge_started", form: form, mission: mission) }
        #expect(throws: refused) { try store.saveAnswer("", to: "bridge_started", form: form, mission: mission) }
        #expect(throws: refused) { try store.saveAnswer("6.2", to: "road_width_m", form: form, mission: mission) }
        #expect(throws: refused) { try store.saveCheck(.notStarted, note: nil, action: action, mission: mission) }
        #expect(throws: refused) { try store.finishWalk(form: form, version: "2026110401", mission: mission) }
        // Only the app's own guard can refuse these: the database sees no row to change.
        #expect(throws: refused) { try store.saveAnswer("", to: "drainage_present", form: form, mission: mission) }
        #expect(throws: refused) {
            try store.saveCheck(.done, note: nil, action: String(repeating: "b", count: 64), mission: mission)
        }
        #expect(try store.answers(form: Self.form, mission: mission) == ["bridge_started": "yes"])
    }

    @Test(arguments: [
        "UPDATE site_answer SET answered_at = 0",
        "DELETE FROM site_answer",
        "INSERT INTO site_answer VALUES ('kandor-roads', 'kandor_road_check', 'drainage_present', x'00', 0)",
        "UPDATE action_check SET seen = 'done'",
        "UPDATE action_check SET photo_seq = 1",
        "DELETE FROM action_check",
        "UPDATE site_walk_finished SET finished_at = 0",
        "DELETE FROM site_walk_finished"
    ])
    func theDatabaseItselfRefusesChangesAfterTheEnd(sql: String) throws {
        // The rule lives in the database (triggers), so no code path can skip it.
        let store = try store()
        try store.saveAnswer("yes", to: "bridge_started", form: Self.form, mission: mission)
        try store.saveCheck(.done, note: nil, action: bridgeAction, mission: mission)
        try store.finishWalk(form: Self.form, version: "2026110401", mission: mission)

        #expect(throws: DatabaseError.self) { try store.store.rawExecuteForTests(sql) }
    }

    @Test func theAuditLogNamesTheQuestionAndTheActionNeverAValue() throws {
        let store = try store()
        try store.saveAnswer("KN-0042", to: "board_ref", form: Self.form, mission: mission)
        try store.saveCheck(.done, note: "Bridge piers seen", action: bridgeAction, mission: mission)
        try store.finishWalk(form: Self.form, version: "2026110401", mission: mission)

        let events = try store.store.auditEvents().filter { $0.mission == mission }
        let walk = events.filter { [.siteAnswered, .actionChecked, .siteWalkFinished].contains($0.action) }
        #expect(walk.map(\.action) == [.siteAnswered, .actionChecked, .siteWalkFinished])
        #expect(walk.map(\.target) == ["board_ref", bridgeAction, "\(Self.form) 2026110401"])
        #expect(!events.contains { ($0.target ?? "").contains("KN-0042") || ($0.target ?? "").contains("piers") })
        #expect(try store.store.verifyAudit() == .valid(count: try store.store.auditEvents().count))
    }

    @Test func aMissionsNextLifeStartsWithAFreshWalk() throws {
        // #94: a shredded mission taken again starts clean; its old answers go with its old life.
        let store = try store()
        try store.saveAnswer("yes", to: "bridge_started", form: Self.form, mission: mission)
        try store.finishWalk(form: Self.form, version: "2026110401", mission: mission)

        try store.reprovision(mission, at: Date())
        try store.create(mission: mission, title: "Kandor rural roads")

        #expect(try store.answers(form: Self.form, mission: mission).isEmpty)
        #expect(try store.finishedWalk(form: Self.form, mission: mission) == nil)
        try store.saveAnswer("no", to: "bridge_started", form: Self.form, mission: mission)
    }

    @Test func aStoreFromTheLastBuildGainsTheWalkTables() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let key = try DataKey.random()
        _ = try EncryptedStore.open(at: file, key: key, upTo: "v10-mission-lives")

        let upgraded = try EncryptedStore.open(at: file, key: key)

        #expect(Array(try upgraded.appliedMigrations().drop { $0 != "v11-site-walk" }.prefix(2))
                == ["v11-site-walk", "v12-action-photo"])
        let tables = try upgraded.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(Set(["site_answer", "action_check", "site_walk_finished"]).isSubset(of: Set(tables)))
    }
}
