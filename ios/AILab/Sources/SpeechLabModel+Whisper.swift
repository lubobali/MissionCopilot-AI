#if canImport(WhisperKit)
import Foundation
import os
import WhisperKit

/// WhisperKit (large-v3, 626 MB) from a folder copied to the phone, tokenizer included, so it never goes
/// online (download: false). Loaded, used, then unloaded before the LLM may load (memory budget).
extension SpeechLabModel {
    static let whisperFolder = DeviceInfo.documents.appendingPathComponent("whisperkit", isDirectory: true)

    enum WhisperRuns { case debriefs, frenchRepeat, voice }

    /// `.debriefs`: both Mac-voice debriefs with VAD chunking. `.frenchRepeat`: French only, with VAD
    /// chunking and without, to tell whether a dropped passage repeats. `.voice`: every Documents/voice file.
    func runWhisper(_ which: WhisperRuns = .debriefs) {
        typealias Run = (label: String, audio: URL?, language: Language, chunking: ChunkingStrategy?)
        let runs: [Run] = switch which {
        case .debriefs: [("whisper", nil, .en, .vad), ("whisper", nil, .fr, .vad)]
        case .frenchRepeat: [("whisper vad repeat", nil, .fr, .vad), ("whisper no-chunking repeat", nil, .fr, nil)]
        case .voice: Self.voiceFiles().map { ("whisper \($0.deletingPathExtension().lastPathComponent)", $0, .en, .vad) }
        }
        task {
            self.record("whisper: network during run", await DeviceInfo.networkStatus())
            let model = Self.whisperFolder.appendingPathComponent("openai_whisper-large-v3-v20240930_626MB").path
            let tokenizer = Self.whisperFolder.appendingPathComponent("tokenizer", isDirectory: true)
            guard FileManager.default.fileExists(atPath: model) else {
                return self.log("Model folder missing: copy it to Documents/whisperkit first.")
            }
            let freeBefore = DeviceInfo.freeMemoryMB()
            do {
                let loadStart = Date()
                let whisper = try await WhisperKit(WhisperKitConfig(modelFolder: model, tokenizerFolder: tokenizer,
                                                                    download: false))
                // The first load compiles the model for this phone's chips; later loads are faster.
                self.record("whisper: load", String(format: "%.1f s, free memory %d -> %d MB", Date().timeIntervalSince(loadStart),
                                                    freeBefore, DeviceInfo.freeMemoryMB()))
                for run in runs {
                    let start = Date()
                    let options = DecodingOptions(task: .transcribe, language: run.language.rawValue, temperature: 0,
                                                  chunkingStrategy: run.chunking)
                    let audio = try run.audio ?? Self.audioURL(run.language)
                    let results = try await whisper.transcribe(audioPath: audio.path, decodeOptions: options)
                    let text = results.map(\.text).joined(separator: " ")
                    try self.score(engine: run.label, language: run.language, transcript: text,
                                   seconds: Date().timeIntervalSince(start), audio: audio)
                }
                self.record("whisper: free memory after runs", "\(DeviceInfo.freeMemoryMB()) MB")
                await whisper.unloadModels()
                self.record("whisper: free memory after unload", "\(DeviceInfo.freeMemoryMB()) MB")
            } catch {
                self.record("whisper", "FAILED: \(error)")
            }
        }
    }
}
#endif
