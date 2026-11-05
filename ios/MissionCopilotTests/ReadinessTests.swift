import Foundation
import Testing
@testable import MissionCopilot

/// The workspace's "Before you go" gathers its facts here (#125): the model inside the app (checked once),
/// the speech files for the mission's languages, and free space; Install runs from the line's button.
@MainActor
struct ReadinessTests {
    let row = MissionRow(id: "a", title: "Kandor Rural Roads Project, Package 1",
                         status: .ready(updated: MissionWordsTests.nov3), pack: ScreenshotTests.sampleRows[0].pack,
                         updateAvailable: false, canDownload: false, note: nil)

    final class Counter: @unchecked Sendable { var checks = 0 }

    func readiness(speech: FakeSpeechFiles, counter: Counter = Counter(),
                   model: BundledModel.State = .verified(files: 9), free: Int64 = 12_000_000_000) -> Readiness {
        Readiness(model: { counter.checks += 1; return model }, speech: speech, freeBytes: { free },
                  words: MissionWordsTests.words)
    }

    @Test func itGathersThePackTheModelTheMissionsLanguagesAndFreeSpace() async {
        let readiness = readiness(speech: FakeSpeechFiles([.english: .installed, .french: .canInstall]))

        await readiness.refresh(row)

        let check = try? #require(readiness.check)
        #expect(check?.lines.map(\.title) == ["Mission pack", "AI assistant", "Speech: English", "Speech: French",
                                              "Free space"])
        #expect(check?.lines[3].state == .toDo)
        #expect(check?.summary == "1 thing to do before you go")
    }

    @Test func theModelIsCheckedOnceItsFilesCannotChangeWhileTheAppRuns() async {
        let counter = Counter()
        let readiness = readiness(speech: FakeSpeechFiles([.english: .installed]), counter: counter)

        await readiness.refresh(row)
        await readiness.refresh(row)

        #expect(counter.checks == 1)
    }

    @Test func installPutsTheLanguageOnThePhoneAndTheLineTurnsReady() async {
        let speech = FakeSpeechFiles([.english: .installed, .french: .canInstall])
        let readiness = readiness(speech: speech)
        await readiness.refresh(row)

        await readiness.install(.french, for: row)

        #expect(await speech.installed == [.french])
        #expect(readiness.check?.lines[3].state == .ready)
        #expect(readiness.check?.isReady == true)
        #expect(readiness.installing == nil)
        #expect(readiness.problem == nil)
    }

    @Test func aFailedInstallSaysSoAndTheLineStaysAThingToDo() async {
        let readiness = readiness(speech: FakeSpeechFiles([.english: .installed, .french: .canInstall],
                                                          installFails: true))
        await readiness.refresh(row)

        await readiness.install(.french, for: row)

        #expect(readiness.problem == "French could not be installed. Check the connection and try again.")
        #expect(readiness.check?.lines[3].state == .toDo)
        #expect(readiness.installing == nil)
    }

    @Test func thePhonesFreeSpaceIsRead() {
        #expect(Readiness.liveFreeBytes() > 0)
    }
}
