@testable import MissionCopilot

/// Speech files that answer what the test says; install makes a language installed, or fails when told.
actor FakeSpeechFiles: SpeechFiles {
    struct InstallFailed: Error {}

    private var statuses: [SpeechLanguage: SpeechFileStatus]
    private let installFails: Bool
    private(set) var installed: [SpeechLanguage] = []

    init(_ statuses: [SpeechLanguage: SpeechFileStatus], installFails: Bool = false) {
        self.statuses = statuses
        self.installFails = installFails
    }

    func status(of language: SpeechLanguage) async -> SpeechFileStatus { statuses[language] ?? .notSupported }

    func install(_ language: SpeechLanguage) async throws {
        installed.append(language)
        if installFails { throw InstallFailed() }
        statuses[language] = .installed
    }
}
