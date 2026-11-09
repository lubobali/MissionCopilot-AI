import Foundation
import Speech

/// A language the officer may speak in a debrief (#125). English always; French when the mission's
/// checklist is in French (the pack says which languages the mission works in).
enum SpeechLanguage: String, CaseIterable, Sendable {
    case english = "en", french = "fr"

    /// The locale Apple's speech engine was proven with on the iPhone (spike #14).
    var locale: Locale { Locale(identifier: self == .english ? "en_US" : "fr_FR") }
    var name: String { self == .english ? "English" : "French" }

    static func needed(for checklist: ChecklistSummary?) -> [SpeechLanguage] {
        checklist?.french == true ? [.english, .french] : [.english]
    }
}

/// Whether a language's speech files are on this iPhone, in words the officer can act on.
enum SpeechFileStatus: Equatable, Sendable {
    case installed, canInstall, installing, notSupported

    /// Only a missing language that this iPhone supports needs the phone online, to install it.
    var needsConnection: Bool { self == .canInstall }
}

/// The phone's speech files. Apple's on the phone; a fake in tests, where the Simulator cannot tell.
protocol SpeechFiles: Sendable {
    func status(of language: SpeechLanguage) async -> SpeechFileStatus
    func install(_ language: SpeechLanguage) async throws
}

/// Apple's speech files (SpeechTranscriber, iOS 26). They are system files: nothing ships in the app, and
/// iOS may remove them when unused, so the app asks before every mission (spike #14).
struct AppleSpeechFiles: SpeechFiles {
    func status(of language: SpeechLanguage) async -> SpeechFileStatus {
        // DictationTranscriber has no isAvailable: the asset inventory says unsupported on a phone without it.
        return Self.status(from: await AssetInventory.status(forModules: [Self.transcriber(language)]))
    }

    /// Needs a connection: Apple downloads the language files (French took 15 s on the iPhone).
    func install(_ language: SpeechLanguage) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [Self.transcriber(language)]) {
            try await request.downloadAndInstall()
        }
    }

    static func status(from apple: AssetInventory.Status) -> SpeechFileStatus {
        switch apple {
        case .installed: .installed
        case .supported: .canInstall
        case .downloading: .installing
        case .unsupported: .notSupported
        @unknown default: .notSupported
        }
    }

    /// DictationTranscriber (#153): it takes the mission's names, and gives each word's confidence.
    static func transcriber(_ language: SpeechLanguage) -> DictationTranscriber {
        DictationTranscriber(locale: language.locale, contentHints: [],
                             transcriptionOptions: DictationTranscriber.Preset.longDictation.transcriptionOptions,
                             reportingOptions: DictationTranscriber.Preset.longDictation.reportingOptions,
                             attributeOptions: [.transcriptionConfidence])
    }
}
