import Foundation
import Testing
@testable import MissionCopilot

/// What a mission's row says (#92): the pack on the phone decides, Ready until 7 days before it expires,
/// then Expires soon (amber), then Expired (red, not used). A running download always shows its bytes; a
/// paused or failed update under a pack that still works stays a note, so the officer is never told a
/// working mission is not ready. With no usable pack the download's state is the status.
struct MissionStatusTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400

    private func pack(expiresIn seconds: TimeInterval, imported: Date = now) -> StoredPack {
        StoredPack(packId: "p", version: 1, manifestSHA256: String(repeating: "0", count: 64),
                   createdAt: imported, expiresAt: Self.now.addingTimeInterval(seconds), importedAt: imported,
                   files: [], project: PackProject(projectRef: "", title: "", country: "", sector: "", status: "",
                                                   developmentObjective: "", implementingAgency: "", approvalDate: "",
                                                   closingDate: "", site: "", currency: "", note: "", budget: 0))
    }

    private func status(_ stored: StoredPack?, _ activity: MissionActivity? = nil, listed: Bool = true)
        -> MissionStatus {
        MissionStatus.of(stored: stored, activity: activity, listed: listed, now: Self.now)
    }

    @Test func noPackOnThePhoneIsNotDownloadedAndSaysWhetherOneCanBe() {
        #expect(status(nil) == .notDownloaded(available: true))
        #expect(status(nil, listed: false) == .notDownloaded(available: false))
    }

    @Test func aPackIsReadyUntilSevenDaysBeforeItExpires() {
        let imported = Self.now.addingTimeInterval(-Self.day)
        let fine = pack(expiresIn: 7 * Self.day + 1, imported: imported)
        let soon = pack(expiresIn: 7 * Self.day, imported: imported)

        #expect(status(fine) == .ready(updated: imported))
        #expect(status(soon) == .expiring(updated: imported, expires: soon.expiresAt))
    }

    @Test func aPackIsExpiredAtItsExpiryTimeExactly() {
        let last = pack(expiresIn: 1), gone = pack(expiresIn: 0)

        #expect(status(last) == .expiring(updated: Self.now, expires: last.expiresAt))
        #expect(status(gone) == .expired(expires: gone.expiresAt))
    }

    @Test func aRunningDownloadAlwaysShowsItsBytes() {
        let running = MissionActivity.downloading(done: 10, total: 20)

        #expect(status(nil, running) == .downloading(done: 10, total: 20))
        #expect(status(pack(expiresIn: 30 * Self.day), running) == .downloading(done: 10, total: 20))
    }

    @Test func aStoppedUpdateUnderAWorkingPackLeavesTheMissionReady() {
        let working = pack(expiresIn: 30 * Self.day)

        #expect(status(working, .paused(.offline)) == .ready(updated: Self.now))
        #expect(status(working, .failed(.notFound)) == .ready(updated: Self.now))
    }

    @Test func withNoUsablePackTheStoppedDownloadIsTheStatus() {
        #expect(status(nil, .paused(.offline)) == .paused(.offline))
        #expect(status(nil, .failed(.notEnoughSpace(needed: 3, available: 1))) == .failed(.notEnoughSpace(
            needed: 3, available: 1)))
        #expect(status(pack(expiresIn: -1), .paused(.locked)) == .paused(.locked))
    }

    @Test func eachStatusShowsTheThemesLabel() {
        #expect(MissionStatus.ready(updated: Self.now).kind == .ready)
        #expect(MissionStatus.expiring(updated: Self.now, expires: Self.now).kind == .expiring)
        #expect(MissionStatus.expired(expires: Self.now).kind == .expired)
        #expect(MissionStatus.paused(.interrupted).kind == .paused)
        #expect(MissionStatus.downloading(done: 0, total: 1).kind == .downloading)
        #expect(MissionStatus.notDownloaded(available: false).kind == .notDownloaded)
        #expect(MissionStatus.failed(.notFound).kind == .failed)
    }
}
