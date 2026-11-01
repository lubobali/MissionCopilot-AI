import AVFoundation
import Foundation

/// Spike #14, real voice: record the English debrief read aloud into Documents/voice (on the phone only,
/// never bundled or committed), then buttons 6 and 7 score it like every other voice file.
extension SpeechLabModel {
    var isRecording: Bool { recorder != nil }

    /// "quiet" or "noisy" while recording, from the file name.
    var recordingRound: String? {
        recorder.map { $0.url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "lubo-real-en-", with: "") }
    }

    func toggleRecording(round: String) {
        if let recorder, recorder.isRecording {
            recorder.stop()
            log("recorded \(recorder.url.lastPathComponent): \(Int(recorder.currentTime.rounded())) s")
            self.recorder = nil
            try? AVAudioSession.sharedInstance().setActive(false)
            return
        }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else { return log("Microphone not allowed.") }
            do {
                try FileManager.default.createDirectory(at: Self.voiceFolder, withIntermediateDirectories: true)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement)  // no voice processing: the raw mic
                try session.setActive(true)
                let url = Self.voiceFolder.appendingPathComponent("lubo-real-en-\(round).m4a")
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                guard recorder.record() else { return log("Recording did not start.") }
                self.recorder = recorder
                log("recording \(url.lastPathComponent)... tap again to stop")
            } catch {
                log("record FAILED: \(error)")
            }
        }
    }

    /// The English script to read aloud, the same text the scores compare against.
    var englishScript: String { (try? Self.script(.en).text) ?? "Script not found." }
}
