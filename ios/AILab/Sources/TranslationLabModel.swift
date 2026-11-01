import Foundation
import Observation
import SpeechLab
@preconcurrency import Translation  // Apple has not marked its types Sendable yet

/// Spike #18 on the iPhone: is Apple's translation offline, and do the numbers survive? Translates the
/// #14 French debrief script to English in airplane mode and scores the 11 key facts against the English
/// answer key with the #14 scorer. The script is the input (not a transcript), so only translation errors
/// count. Debug lab only.
@MainActor @Observable
final class TranslationLabModel {
    nonisolated static let french = Locale.Language(identifier: "fr")
    nonisolated static let english = Locale.Language(identifier: "en")
    static let checked = ["fr", "es", "pt", "ar"].map { Locale.Language(identifier: $0) }

    var log: [String] = ["Start with: Translation status."]
    var running = false
    /// Set to ask SwiftUI's translationTask for a session that may download (needs the network once).
    var installConfiguration: TranslationSession.Configuration?
    private var results: [String: String] = [:]

    func status() {
        task {
            let availability = LanguageAvailability()
            let supported = await availability.supportedLanguages
            self.record("supported languages", "\(supported.count): "
                        + supported.map { $0.minimalIdentifier }.sorted().joined(separator: " "))
            for language in Self.checked {
                let toEnglish = await availability.status(from: language, to: Self.english)
                self.record("status \(language.minimalIdentifier)->en", "\(toEnglish)")
            }
            self.record("status en->fr", "\(await availability.status(from: Self.english, to: Self.french))")
        }
    }

    func requestInstall() {
        installConfiguration = TranslationSession.Configuration(source: Self.french, target: Self.english)
    }

    /// Called by translationTask with a session that may show Apple's download prompt.
    func install(with session: TranslationSession) async {
        let start = Date()
        do {
            try await session.prepareTranslation()
            record("install fr->en", "ready in \(Int(Date().timeIntervalSince(start))) s")
        } catch {
            record("install fr->en", "FAILED: \(error)")
        }
        save()
    }

    func run() {
        guard #available(iOS 26.0, *) else { return log.append("Needs iOS 26 or later.") }
        task {
            self.record("network during run", await DeviceInfo.networkStatus())
            for label in ["default", "lowLatency", "highFidelity"] { await self.translate(label: label) }
        }
    }

    @available(iOS 26.0, *)
    /// One request per sentence, so a dropped sentence shows up instead of hiding in one long answer.
    private func translate(label: String) async {
        do {
            let french = try SpeechLabModel.script(.fr).text
            let english = try SpeechLabModel.script(.en)
            let sentences = Self.sentences(french)
            let start = Date()
            let translated = try await Self.translations(of: sentences, strategy: label)
            let seconds = Date().timeIntervalSince(start)
            let text = translated.joined(separator: " ")
            let facts = FactScore.score(english.facts, in: text, language: "en")
            record("translate \(label)", String(format: "facts %d/%d, %d of %d sentences, %.2f s",
                                                facts.found.count, english.facts.count, translated.count,
                                                sentences.count, seconds))
            if !facts.missing.isEmpty { record("translate \(label) facts missing", facts.missing.joined(separator: ", ")) }
            record("translate \(label) text", text)
        } catch {
            record("translate \(label)", "FAILED: \(error)")
        }
    }

    /// The session and its requests stay inside this function (Apple's types are not Sendable yet).
    @available(iOS 26.0, *)
    nonisolated static func translations(of sentences: [String], strategy: String) async throws -> [String] {
        let session: TranslationSession
        if #available(iOS 26.4, *), strategy != "default" {
            session = TranslationSession(installedSource: french, target: english,
                                         preferredStrategy: strategy == "highFidelity" ? .highFidelity : .lowLatency)
        } else {
            session = TranslationSession(installedSource: french, target: english)
        }
        let responses = try await session.translations(from: sentences.map { TranslationSession.Request(sourceText: $0) })
        return responses.map(\.targetText)
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty { out.append(sentence) }
        }
        return out
    }

    private func task(_ body: @escaping @MainActor () async -> Void) {
        running = true
        Task {
            await body()
            save()
            running = false
        }
    }

    private func record(_ name: String, _ value: String) {
        results[name] = value
        log.append(name + ": " + value)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(results).write(to: DeviceInfo.documents.appendingPathComponent("translation-results.json"))
        } catch {
            log.append("save FAILED: \(error)")
        }
    }
}
