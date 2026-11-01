#if canImport(WhisperKit)
import Foundation
import os
import WhisperKit

/// WhisperKit (large-v3, 626 MB) from a folder copied to the phone, tokenizer included, so it never goes
/// online (download: false). Loaded, used, then unloaded before the LLM may load (memory budget).
extension SpeechLabModel {
    static let whisperFolder = DeviceInfo.documents.appendingPathComponent("whisperkit", isDirectory: true)

    /// Both debriefs with VAD chunking; `frenchRepeat` instead runs only French, once with VAD chunking and
    /// once without, to tell whether a dropped passage repeats and whether chunking causes it.
    func runWhisper(frenchRepeat: Bool = false) {
        let runs: [(Language, ChunkingStrategy?)] = frenchRepeat ? [(.fr, .vad), (.fr, nil)] : [(.en, .vad), (.fr, .vad)]
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
                for (language, chunking) in runs {
                    let start = Date()
                    let options = DecodingOptions(task: .transcribe, language: language.rawValue, temperature: 0,
                                                  chunkingStrategy: chunking)
                    let results = try await whisper.transcribe(audioPath: Self.audioURL(language).path, decodeOptions: options)
                    let text = results.map(\.text).joined(separator: " ")
                    let engine = frenchRepeat ? "whisper \(chunking == nil ? "no-chunking" : "vad") repeat" : "whisper"
                    try self.score(engine: engine, language: language, transcript: text,
                                   seconds: Date().timeIntervalSince(start))
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
