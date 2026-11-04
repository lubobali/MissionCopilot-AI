import Foundation
import Testing
@testable import MissionCopilot

/// What a mission row and its pack summary say (#92): sizes in bytes, KB or MB as the size needs, a day
/// for every date, each stopped download its own reason, and a button that says what it does.
struct MissionWordsTests {
    static let words = MissionWords(locale: Locale(identifier: "en_US"), timeZone: .gmt)
    static let nov3 = Date(timeIntervalSince1970: 1_793_664_000)  // 2026-11-03 00:00 UTC
    static let nov10 = nov3.addingTimeInterval(7 * 86_400)

    static func row(_ status: MissionStatus, pack: PackFacts? = nil, update: Bool = false,
                    canDownload: Bool = true) -> MissionRow {
        MissionRow(id: "m", title: "Kandor Bridges", status: status, pack: pack, updateAvailable: update,
                   canDownload: canDownload, note: nil)
    }

    // Sizes and days

    @Test func sizesUseBytesKBOrMBAsTheSizeNeeds() {
        #expect(Self.words.size(900) == "900 bytes")
        #expect(Self.words.size(48_000) == "48 kB")
        #expect(Self.words.size(3_400_000) == "3.4 MB")
    }

    @Test func aDownloadShowsHowMuchOfHowMuchHasArrived() {
        #expect(Self.words.detail(.downloading(done: 1_200_000, total: 3_400_000)) == "1.2 MB of 3.4 MB")
        #expect(Self.words.detail(.downloading(done: 0, total: 0)) == "Starting")
    }

    @Test func aReadyPackSaysWhenItWasUpdatedAndAnExpiringOneWhenItEnds() {
        #expect(Self.words.detail(.ready(updated: Self.nov3)) == "Updated Nov 3, 2026")
        #expect(Self.words.detail(.expiring(updated: Self.nov3, expires: Self.nov10)) == "Expires Nov 10, 2026")
        #expect(Self.words.detail(.expired(expires: Self.nov10)) == "Expired Nov 10, 2026. Download it again.")
    }

    // Not downloaded, stopped, failed

    @Test func notDownloadedSaysWhetherTheServerHasAPackYet() {
        #expect(Self.words.detail(.notDownloaded(available: true)) == "Ready to download.")
        #expect(Self.words.detail(.notDownloaded(available: false)) == "No pack published yet. Check again later.")
    }

    @Test func eachStoppedDownloadSaysItsOwnReasonAndThatItGoesOn() {
        let pauses: [MissionPause] = [.offline, .interrupted, .slowDown(30), .locked]
        let texts = pauses.map { Self.words.detail(.paused($0)) ?? "" }

        #expect(Set(texts).count == pauses.count)
        #expect(texts[0] == "Waiting for connection. It goes on by itself.")
        #expect(texts[2] == "The server is busy. It goes on in 30 seconds.")
        #expect(texts[3] == "Downloaded. It is added when you unlock the app.")
        #expect(!texts[3].contains("connection"))  // a locked phone is not offline
    }

    @Test func aFailedDownloadSaysWhyAsASentence() {
        #expect(Self.words.detail(.failed(.notFound)) == "The server has no pack for this mission.")
    }

    @Test func notEnoughSpaceSaysHowMuchIsNeededAndHowMuchIsFree() {
        #expect(Self.words.detail(.failed(.notEnoughSpace(needed: 5_000_000, available: 1_000_000)))
            == "Not enough free space: the pack needs 5 MB, this iPhone has 1 MB free.")
    }

    // The button

    @Test func theButtonSaysWhatItDownloads() {
        #expect(Self.words.action(Self.row(.notDownloaded(available: true))) == "Download")
        #expect(Self.words.action(Self.row(.ready(updated: Self.nov3), update: true)) == "Download update")
        #expect(Self.words.action(Self.row(.expired(expires: Self.nov10))) == "Download again")
        #expect(Self.words.action(Self.row(.failed(.server(500)))) == "Try again")
    }

    // The pack summary

    @Test func thePackSummaryListsVersionFilesAndDates() {
        let pack = PackFacts(version: 3, files: 12, bytes: 48_000, projectRef: "KN-RR-001",
                             published: Self.nov3, downloaded: Self.nov3, expires: Self.nov10)

        let facts = Self.words.summary(pack)

        #expect(facts.map(\.label) == ["Project", "Version", "Files", "Published", "Downloaded", "Expires"])
        #expect(facts.map(\.value) == ["KN-RR-001", "3", "12 files, 48 kB", "Nov 3, 2026", "Nov 3, 2026",
                                       "Nov 10, 2026"])
    }

    @Test func thePackSummarySaysHowManyQuestionsTheChecklistHasAndInWhichLanguages() {
        let both = PackFacts(version: 3, files: 12, bytes: 48_000, projectRef: "KN-RR-001", published: Self.nov3,
                             downloaded: Self.nov3, expires: Self.nov10,
                             checklist: ChecklistSummary(questions: 9, french: true))
        let one = PackFacts(version: 1, files: 1, bytes: 900, projectRef: "KN", published: Self.nov3,
                            downloaded: Self.nov3, expires: Self.nov10,
                            checklist: ChecklistSummary(questions: 1, french: false))

        #expect(Self.words.summary(both).last == .init(label: "Checklist", value: "9 questions, English and French"))
        #expect(Self.words.summary(one).last == .init(label: "Checklist", value: "1 question, English"))
    }

    @Test func oneFileIsSaidAsOneFile() {
        let pack = PackFacts(version: 1, files: 1, bytes: 900, projectRef: "KN", published: Self.nov3,
                             downloaded: Self.nov3, expires: Self.nov10)

        #expect(Self.words.summary(pack)[2].value == "1 file, 900 bytes")
    }
}
