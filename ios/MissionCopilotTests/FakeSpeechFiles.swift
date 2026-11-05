@testable import MissionCopilot

/// Speech files that answer what the test says; install makes a language installed.
actor FakeSpeechFiles: SpeechFiles {
    private var statuses: [SpeechLanguage: SpeechFileStatus]
    private(set) var installed: [SpeechLanguage] = []

    init(_ statuses: [SpeechLanguage: SpeechFileStatus]) { self.statuses = statuses }

    func status(of language: SpeechLanguage) async -> SpeechFileStatus { statuses[language] ?? .notSupported }

    func install(_ language: SpeechLanguage) async throws {
        installed.append(language)
        statuses[language] = .installed
    }
}
