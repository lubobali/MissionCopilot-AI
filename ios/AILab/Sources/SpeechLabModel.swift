import AVFoundation
import Foundation
import Observation
import Speech
import SpeechLab

/// Spike #14 on the iPhone: transcribe the debrief audio offline with Apple's SpeechTranscriber and with
/// WhisperKit, and score each by code (word error rate and the 11 key facts). Debug lab only.
@MainActor @Observable
final class SpeechLabModel {
    enum Language: String, CaseIterable {
        case en, fr
        var locale: Locale { Locale(identifier: self == .en ? "en_US" : "fr_FR") }
    }

    struct Script: Decodable {
        let voice: String
        let text: String
        let facts: [SpokenFact]
    }

    var log: [String] = ["Start with: Apple status."]
    var running = false
    private var results: [String: String] = [:]

    // MARK: - Apple SpeechTranscriber

    func appleStatus() {
        guard #available(iOS 26.0, *) else { return log("Needs iOS 26 or later.") }
        task {
            self.record("apple: SpeechTranscriber.isAvailable", "\(SpeechTranscriber.isAvailable)")
            let supported = await SpeechTranscriber.supportedLocales.map(\.identifier)
            let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
            for language in Language.allCases {
                let id = language.locale.identifier
                let status = await AssetInventory.status(forModules: [Self.transcriber(language)])
                self.record("apple: \(id)", "supported \(supported.contains(id)), installed \(installed.contains(id)), "
                            + "asset status \(status)")
            }
        }
    }

    /// Needs the network once: Apple downloads the language files. The app must check this before a mission.
    func appleInstall() {
        guard #available(iOS 26.0, *) else { return log("Needs iOS 26 or later.") }
        task {
            for language in Language.allCases {
                let start = Date()
                do {
                    if let request = try await AssetInventory.assetInstallationRequest(
                        supporting: [Self.transcriber(language)]) {
                        try await request.downloadAndInstall()
                    }
                    let status = await AssetInventory.status(forModules: [Self.transcriber(language)])
                    self.record("apple install \(language.rawValue)",
                                "\(status) in \(Int(Date().timeIntervalSince(start))) s")
                } catch {
                    self.record("apple install \(language.rawValue)", "FAILED: \(error)")
                }
            }
        }
    }

    func runApple() {
        guard #available(iOS 26.0, *) else { return log("Needs iOS 26 or later.") }
        task {
            self.record("apple: network during run", await DeviceInfo.networkStatus())
            for language in Language.allCases {
                do {
                    let start = Date()
                    let text = try await Self.appleTranscribe(Self.audioURL(language), language: language)
                    try self.score(engine: "apple", language: language, transcript: text,
                                   seconds: Date().timeIntervalSince(start))
                } catch {
                    self.record("apple \(language.rawValue)", "FAILED: \(error)")
                }
            }
        }
    }

    @available(iOS 26.0, *)
    static func transcriber(_ language: Language) -> SpeechTranscriber {
        SpeechTranscriber(locale: language.locale, preset: .transcription)
    }

    @available(iOS 26.0, *)
    static func appleTranscribe(_ url: URL, language: Language) async throws -> String {
        let transcriber = transcriber(language)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collected = Task {
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        try await analyzer.start(inputAudioFile: try AVAudioFile(forReading: url), finishAfterFile: true)
        return try await collected.value
    }

    // MARK: - Scoring and results

    func score(engine: String, language: Language, transcript: String, seconds: Double, audio: URL? = nil) throws {
        let script = try Self.script(language)
        let reference = Normalizer.words(script.text, language: language.rawValue)
        let hypothesis = Normalizer.words(transcript, language: language.rawValue)
        let wer = WordErrorRate.compute(reference: reference, hypothesis: hypothesis)
        let facts = FactScore.score(script.facts, in: transcript, language: language.rawValue)
        let audioSeconds = (try? AVAudioFile(forReading: audio ?? Self.audioURL(language))).map {
            Double($0.length) / $0.processingFormat.sampleRate
        } ?? 0
        record("\(engine) \(language.rawValue)",
               String(format: "WER %.1f%% (sub %d, del %d, ins %d of %d words), facts %d/%d, %.1f s for %.0f s audio",
                      wer.rate * 100, wer.substitutions, wer.deletions, wer.insertions, wer.referenceCount,
                      facts.found.count, script.facts.count, seconds, audioSeconds))
        if !facts.missing.isEmpty { record("\(engine) \(language.rawValue) facts missing", facts.missing.joined(separator: ", ")) }
        record("\(engine) \(language.rawValue) transcript", transcript)
    }

    static func audioURL(_ language: Language) throws -> URL {
        // The audio folder is copied as "audio/" so its answer key does not collide with the scans' key.
        guard let url = Bundle.main.url(forResource: "debrief-\(language.rawValue)", withExtension: "m4a",
                                        subdirectory: "audio") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    static func script(_ language: Language) throws -> Script {
        guard let url = Bundle.main.url(forResource: "answer-key", withExtension: "json", subdirectory: "audio"),
              let key = try? JSONDecoder().decode([String: Script].self, from: Data(contentsOf: url)),
              let script = key[language.rawValue] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return script
    }

    func task(_ body: @escaping @MainActor () async -> Void) {
        running = true
        Task {
            await body()
            save()
            running = false
        }
    }

    func record(_ name: String, _ value: String) {
        results[name] = value
        log.append(name + ": " + value)
    }

    func log(_ line: String) { log.append(line) }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(results).write(to: DeviceInfo.documents.appendingPathComponent("speech-results.json"))
        } catch {
            log("save FAILED: \(error)")
        }
    }
}
