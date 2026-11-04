import Foundation
import Testing
@testable import MissionCopilot

/// The mission list is made once and lives above the lock screen (#92), so a download keeps going while
/// the app is locked, the pack is added at unlock, and a connection coming back reaches the list. A build
/// or phone that cannot list missions yet is asked again the next time, never remembered as broken.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct MissionsHubTests {
    let rig: MissionListModelTests
    let roads = MissionListModelTests.roads

    init() throws { rig = try MissionListModelTests() }

    private func status(_ model: MissionListModel) -> MissionStatus? {
        model.rows.first { $0.id == roads }?.status
    }

    @Test func theListIsMadeOnceAndKeptAcrossALock() throws {
        var made = 0
        let model = try rig.model()
        let hub = MissionsHub(make: { _ in made += 1; return .success(model) }, watch: { _ in })

        let first = hub.open(), second = hub.open()

        #expect(made == 1)
        #expect(try first.get() === second.get())
    }

    @Test func aPhoneNotConnectedYetIsAskedAgainNextTime() throws {
        var answers: [Result<MissionListModel, MissionsHub.Problem>] = [.failure(.notConnected),
                                                                         .success(try rig.model())]
        let hub = MissionsHub(make: { _ in answers.removeFirst() }, watch: { _ in })

        #expect(throws: MissionsHub.Problem.notConnected) { try hub.open().get() }
        #expect(throws: Never.self) { try hub.open().get() }
    }

    @Test func aDestroyedListIsForgotten() throws {
        var made = 0
        let model = try rig.model()
        let hub = MissionsHub(make: { _ in made += 1; return .success(model) }, watch: { _ in })
        _ = hub.open()

        hub.forget()
        _ = hub.open()

        #expect(made == 2)
    }

    @Test(.needsRepoFiles) func theConnectionComingBackReachesTheList() async throws {
        var changed: (@MainActor (Bool) -> Void)?
        let model = try rig.model()
        let hub = MissionsHub(make: { _ in .success(model) }, watch: { changed = $0 })
        _ = hub.open()
        await model.refresh()
        rig.server.dropOnce = 6
        model.download(roads)
        await model.downloadsEnded()

        changed?(true)
        await model.downloadsEnded()

        #expect(status(model) == .ready(updated: MissionListModelTests.now))
    }

    @Test(.needsRepoFiles) func aPackDownloadedWhileLockedIsAddedAtUnlock() async throws {
        let model = try rig.model()
        let hub = MissionsHub(make: { _ in .success(model) }, watch: { _ in })
        _ = hub.open()
        await model.refresh()
        let gate = rig.gate
        rig.server.onFileRequest = { number in if number == 3 { gate.isOpen = false } }
        model.download(roads)
        await model.downloadsEnded()
        gate.isOpen = true

        await hub.unlocked()

        #expect(status(model) == .ready(updated: MissionListModelTests.now))
    }
}
