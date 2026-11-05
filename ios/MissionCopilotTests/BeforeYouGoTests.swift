import Foundation
import Testing
@testable import MissionCopilot

/// "Before you go" (#125): is this iPhone ready for the field, and what to do while still online.
struct BeforeYouGoTests {
    let words = MissionWordsTests.words
    let nov3 = MissionWordsTests.nov3, nov10 = MissionWordsTests.nov10
    var pack: PackFacts {
        PackFacts(version: 9, files: 13, bytes: 15_000_000, projectRef: "KRRP-P1", published: nov3,
                  downloaded: nov3, expires: nov10, checklist: ChecklistSummary(questions: 9, french: true))
    }
    let gigabyte: Int64 = 1_000_000_000

    func check(pack status: MissionStatus = .ready(updated: MissionWordsTests.nov3),
               model: BundledModel.State = .verified(files: 9),
               speech: [SpeechLanguage: SpeechFileStatus] = [.english: .installed, .french: .installed],
               free: Int64 = 12_000_000_000) -> BeforeYouGo {
        BeforeYouGo(pack: status, facts: pack, model: model, speech: speech, freeBytes: free, words: words)
    }

    @Test func allReadyIsReadyForTheField() {
        let ready = check()

        #expect(ready.isReady)
        #expect(ready.summary == "Ready for the field")
        #expect(ready.lines.map(\.state) == [.ready, .ready, .ready, .ready, .ready])
    }

    @Test func theLinesComeInAFixedOrderOneSpeechLinePerLanguage() {
        #expect(check().lines.map(\.title) == ["Mission pack", "AI assistant", "Speech: English", "Speech: French",
                                               "Free space"])
        #expect(check(speech: [.english: .installed]).lines.map(\.title)
                == ["Mission pack", "AI assistant", "Speech: English", "Free space"])
    }

    @Test func aReadyPackSaysItsVersionAndUntilWhenItWorks() {
        let line = check().lines[0]

        #expect(line.detail == "Version 9, works offline until \(words.day(nov10))")
    }

    @Test func thingsToDoAreCountedAndSayWhetherTheyNeedAConnection() {
        let result = check(pack: .expiring(updated: nov3, expires: nov10), speech: [.english: .installed,
                                                                                     .french: .canInstall])

        #expect(!result.isReady)
        #expect(result.summary == "2 things to do before you go")
        #expect(result.lines[0].state == .toDo && result.lines[0].needsConnection)
        #expect(result.lines[0].detail == "Expires \(words.day(nov10)). Update it while online.")
        #expect(result.lines[3].detail == "Not on this iPhone. Install it while online.")
        #expect(result.needsConnection)
    }

    @Test func oneThingIsSaidInTheSingular() {
        #expect(check(free: gigabyte / 2).summary == "1 thing to do before you go")
    }

    @Test(arguments: [
        (MissionStatus.notDownloaded(available: true), "Not downloaded. Download it while online.", true),
        (.expired(expires: MissionWordsTests.nov3), "Expired \(MissionWordsTests.words.day(MissionWordsTests.nov3)). "
            + "Download it again while online.", true),
        (.failed(.storage), "The last download failed. Try again while online.", true),
        (.notDownloaded(available: false), "No pack published for this mission yet.", false)
    ])
    func aPackThatIsNotUsableIsAThingToDo(status: MissionStatus, detail: String, online: Bool) {
        let line = check(pack: status).lines[0]

        #expect(line.state == (online ? .toDo : .cannot))
        #expect(line.detail == detail)
        #expect(line.needsConnection == online)
    }

    @Test func aPackOnItsWayIsGettingReadyNotAThingToDo() {
        let result = check(pack: .downloading(done: 1, total: 2))

        #expect(result.lines[0].state == .working)
        #expect(result.summary == "Getting ready")
        #expect(!result.isReady)
    }

    @Test func aBuildWithoutTheModelOrARefusedOneCannotBeFixedOnline() {
        let missing = check(model: .notInThisBuild).lines[1]
        let refused = check(model: .refused(.signature(.changedFile("model.safetensors")))).lines[1]

        #expect(missing.state == .cannot && !missing.needsConnection)
        #expect(missing.detail == "Not in this build of the app. Install the full app.")
        #expect(refused.state == .cannot && !refused.needsConnection)
        #expect(refused.detail == "It failed its safety check, so it stays off. Install the app again.")
        #expect(check(model: .verified(files: 9)).lines[1].detail == "On this iPhone, checked")
    }

    @Test func speechThatThisIPhoneCannotDoOffersTyping() {
        let line = check(speech: [.english: .installed, .french: .notSupported]).lines[3]

        #expect(line.state == .cannot)
        #expect(line.detail == "This iPhone cannot turn French speech into text. You can type notes instead.")
    }

    @Test func onlyASpeechLineThatCanBeInstalledOffersInstallingItsLanguage() {
        let lines = check(speech: [.english: .installed, .french: .canInstall]).lines

        #expect(lines[3].installs == .french)
        #expect(lines.filter { $0.installs != nil }.count == 1)
    }

    @Test func installingSpeechIsGettingReady() {
        #expect(check(speech: [.english: .installing]).lines[2].state == .working)
    }

    @Test func freeSpaceNeedsTwoGigabytesForPhotosScansAndAudio() {
        #expect(BeforeYouGo.minimumFreeBytes == 2 * gigabyte)
        let low = check(free: 2 * gigabyte - 1).lines[4]
        let enough = check(free: 2 * gigabyte).lines[4]

        #expect(low.state == .toDo && !low.needsConnection)
        #expect(low.detail.hasPrefix("Only ") && low.detail.hasSuffix(" free. Make room for at least 2 GB of photos "
                                                                       + "and scans."))
        #expect(enough.state == .ready)
        #expect(enough.detail == "\(words.size(Int(2 * gigabyte))) free")
    }

    @Test func somethingThisIPhoneCannotDoStillCountsAsAThingToDo() {
        // A build with no model is not "getting ready": the officer must know before leaving.
        let result = check(model: .notInThisBuild)

        #expect(result.summary == "1 thing to do before you go")
        #expect(!result.isReady)
    }

    @Test func lowSpaceAloneMeansNotReady() {
        let result = check(free: gigabyte)

        #expect(!result.isReady)
        #expect(result.summary == "1 thing to do before you go")
    }

    @Test func nothingToDoOnlineWhenEverythingLeftIsOffline() {
        #expect(!check(free: gigabyte).needsConnection)
    }
}
