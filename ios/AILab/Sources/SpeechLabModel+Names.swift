import AVFoundation
import Foundation
import Speech
import SpeechLab

/// #153 spike, on the iPhone: the mission's names in speech, for every accent. Found in the Phase 6 proof: Lubo
/// said "Kandor road visit" and SpeechTranscriber wrote "Counter route visit". Apple's docs: contextual strings
/// (up to 100 names) bias recognition, but only with DictationTranscriber. The same recording of a real voice
/// goes through both engines; code counts the names heard right and the word error rate. Debug lab only; the
/// recordings stay in Documents/voice-names on the phone, never bundled or committed.
extension SpeechLabModel {
    /// The names the app would give the engine: MissionNames of the Kandor pack, plus a person's name.
    static let missionNames = ["Kandor", "KRRP", "Okafor"]

    static let namesScripts: [Language: String] = [
        .en: "Kandor road visit. We met Mister Okafor from Kandor Roadworks about the KRRP package. The Section 3 "
            + "bridge is not started. Invoice 14 for 480,000 dollars was paid on 12 October.",
        .fr: "Visite de la route de Kandor. Nous avons rencontré Monsieur Okafor de Kandor Roadworks pour le projet "
            + "KRRP. Le pont de la section 3 n'est pas commencé. La facture 14 de 480 000 dollars a été payée le "
            + "12 octobre."
    ]

    static var namesFolder: URL { DeviceInfo.documents.appendingPathComponent("voice-names") }

    /// Records one take of a names script, a new file per take ("lubo-names-<lang>-names<lang>-<time>").
    func toggleNamesRecording(_ language: Language) {
        if recorder != nil { return toggleRecording(round: "names\(language.rawValue)") }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else { return log("Microphone not allowed.") }
            do {
                try FileManager.default.createDirectory(at: Self.namesFolder, withIntermediateDirectories: true)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement)
                try session.setActive(true)
                let name = "lubo-names-\(language.rawValue)-names\(language.rawValue)-\(Int(Date().timeIntervalSince1970))"
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000]
                let recorder = try AVAudioRecorder(url: Self.namesFolder.appendingPathComponent(name + ".m4a"),
                                                   settings: settings)
                guard recorder.record() else { return log("Recording did not start.") }
                self.recorder = recorder
                log("recording \(name)... read the script, then tap again to stop")
            } catch {
                log("record FAILED: \(error)")
            }
        }
    }

    /// Needs the network once: the dictation model's files, like SpeechTranscriber's.
    func installDictation() {
        guard #available(iOS 26.0, *) else { return log("Needs iOS 26 or later.") }
        task {
            for language in Language.allCases {
                do {
                    let module = Self.dictation(language)
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                        try await request.downloadAndInstall()
                    }
                    self.record("dictation install \(language.rawValue)",
                                "\(await AssetInventory.status(forModules: [module]))")
                } catch {
                    self.record("dictation install \(language.rawValue)", "FAILED: \(error)")
                }
            }
        }
    }

    /// Every names recording through both engines, offline: names heard right, word error rate, time.
    func compareNames() {
        guard #available(iOS 26.0, *) else { return log("Needs iOS 26 or later.") }
        task {
            self.record("names: network during run", await DeviceInfo.networkStatus())
            let files = (try? FileManager.default.contentsOfDirectory(at: Self.namesFolder,
                                                                      includingPropertiesForKeys: nil)) ?? []
            let takes = files.filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            if takes.isEmpty { return self.log("No names recordings yet: record one first.") }
            for take in takes {
                let language: Language = take.lastPathComponent.contains("-fr-") ? .fr : .en
                let label = take.deletingPathExtension().lastPathComponent
                let engines: [(String, (URL, Language) async throws -> String)] = [
                    ("transcriber", { try await Self.appleTranscribe($0, language: $1) }),
                    ("dictation+names", { try await Self.dictate($0, language: $1) })
                ]
                for (engine, run) in engines {
                    do {
                        let start = Date()
                        let text = try await run(take, language)
                        self.scoreNames(engine: engine, take: label, language: language, transcript: text,
                                        seconds: Date().timeIntervalSince(start))
                    } catch {
                        self.record("\(engine) \(label)", "FAILED: \(error)")
                    }
                }
            }
        }
    }

    func scoreNames(engine: String, take: String, language: Language, transcript: String, seconds: Double) {
        let script = Self.namesScripts[language] ?? ""
        let said = Self.missionNames.reduce(0) { $0 + script.components(separatedBy: $1).count - 1 }
        let heard = Self.missionNames.reduce(0) { total, name in
            total + min(transcript.lowercased().components(separatedBy: name.lowercased()).count - 1,
                        script.components(separatedBy: name).count - 1)
        }
        let wer = WordErrorRate.compute(reference: Normalizer.words(script, language: language.rawValue),
                                        hypothesis: Normalizer.words(transcript, language: language.rawValue))
        record("\(engine) \(take)", String(format: "names %d/%d, WER %.1f%%, %.1f s", heard, said, wer.rate * 100,
                                          seconds))
        record("\(engine) \(take) transcript", transcript)
    }

    @available(iOS 26.0, *)
    static func dictation(_ language: Language) -> DictationTranscriber {
        DictationTranscriber(locale: language.locale, preset: .longDictation)
    }

    /// DictationTranscriber with the mission's names as contextual strings, reading the whole file.
    @available(iOS 26.0, *)
    static func dictate(_ url: URL, language: Language) async throws -> String {
        let transcriber = dictation(language)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = missionNames
        try await analyzer.setContext(context)
        let collected = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) }
            return text
        }
        try await analyzer.start(inputAudioFile: try AVAudioFile(forReading: url), finishAfterFile: true)
        return try await collected.value
    }
}
