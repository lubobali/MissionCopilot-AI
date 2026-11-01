import Foundation

/// Spike #14, real-voice rounds: every .m4a in Documents/voice (copied by cable, never bundled: it is a
/// private voice) is an English debrief read from the same script, scored by code like the Mac voices.
/// File names carry the round: "<name>-quiet", "<name>-road-10db", "<name>-cafe-10db".
extension SpeechLabModel {
    static let voiceFolder = DeviceInfo.documents.appendingPathComponent("voice", isDirectory: true)

    static func voiceFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: voiceFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func runAppleOnVoice() {
        guard #available(iOS 26.0, *) else { return log("Needs iOS 26 or later.") }
        task {
            self.record("voice apple: network during run", await DeviceInfo.networkStatus())
            let files = Self.voiceFiles()
            if files.isEmpty { return self.log("No .m4a files in Documents/voice.") }
            for file in files {
                let round = file.deletingPathExtension().lastPathComponent
                do {
                    let start = Date()
                    let text = try await Self.appleTranscribe(file, language: .en)
                    try self.score(engine: "apple \(round)", language: .en, transcript: text,
                                   seconds: Date().timeIntervalSince(start), audio: file)
                } catch {
                    self.record("apple \(round) en", "FAILED: \(error)")
                }
            }
        }
    }
}
