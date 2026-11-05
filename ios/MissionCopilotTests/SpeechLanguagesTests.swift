import Foundation
import Speech
import Testing
@testable import MissionCopilot

/// Before a mission the phone needs the speech files for every language the officer may speak (#125):
/// English always, and French when the mission's checklist is in French. iOS may remove unused speech
/// files, so they are checked before every mission and installed while the phone is still online.
struct SpeechLanguagesTests {
    @Test func englishIsAlwaysNeeded() {
        #expect(SpeechLanguage.needed(for: nil) == [.english])
        #expect(SpeechLanguage.needed(for: ChecklistSummary(questions: 9, french: false)) == [.english])
    }

    @Test func aChecklistInFrenchAddsFrench() {
        #expect(SpeechLanguage.needed(for: ChecklistSummary(questions: 9, french: true)) == [.english, .french])
    }

    @Test func eachLanguageHasTheLocaleTheSpeechEngineUsesAndAName() {
        #expect(SpeechLanguage.english.locale.identifier == "en_US")
        #expect(SpeechLanguage.french.locale.identifier == "fr_FR")
        #expect(SpeechLanguage.english.name == "English")
        #expect(SpeechLanguage.french.name == "French")
    }

    @Test func appleStatusesBecomeWordsTheOfficerCanActOn() {
        // Apple's status is not Sendable, so not a test argument: the four cases in one test.
        #expect(AppleSpeechFiles.status(from: .installed) == .installed)
        #expect(AppleSpeechFiles.status(from: .supported) == .canInstall)
        #expect(AppleSpeechFiles.status(from: .downloading) == .installing)
        #expect(AppleSpeechFiles.status(from: .unsupported) == .notSupported)
    }

    @Test func onlyAMissingButSupportedLanguageNeedsAConnection() {
        #expect(SpeechFileStatus.canInstall.needsConnection)
        #expect(!SpeechFileStatus.installed.needsConnection)
        #expect(!SpeechFileStatus.installing.needsConnection)
        #expect(!SpeechFileStatus.notSupported.needsConnection)
    }

    @Test func theFakeAnswersWhatItWasToldAndInstallsOnRequest() async throws {
        let files = FakeSpeechFiles([.english: .installed, .french: .canInstall])

        #expect(await files.status(of: .french) == .canInstall)
        try await files.install(.french)
        #expect(await files.status(of: .french) == .installed)
    }
}
