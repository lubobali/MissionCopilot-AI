import AVFoundation
import Foundation

/// A finished recording: its file (in the app's own temporary folder until it is kept) and its length.
struct Recording: Equatable, Sendable {
    let file: URL
    let seconds: Double
}

/// Why the microphone did not record, in words the officer can act on.
enum RecordingProblem: Error, Equatable, Sendable {
    case microphoneDenied, couldNotStart

    var words: String {
        switch self {
        case .microphoneDenied: "The microphone is off for Mission Copilot. Turn it on in Settings, Mission Copilot."
        case .couldNotStart: "The recording did not start. Try again."
        }
    }
}

/// The microphone, for a debrief (#142). The real one is below; tests use a fake.
@MainActor
protocol DebriefRecorder: AnyObject {
    /// How long the current recording has run.
    var seconds: Double { get }
    func start() async throws
    func stop() -> Recording?
    /// Stops and deletes the file: a cancelled debrief leaves nothing.
    func cancel()
}

/// The iPhone's microphone with spike #14's settings (proven there): the raw microphone (no voice processing),
/// AAC at 16 kHz, one channel, written into the app's temporary folder with Complete file protection, never
/// longer than the limit. The microphone is on only between start and stop.
@MainActor
final class MicrophoneRecorder: DebriefRecorder {
    static let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16_000,
                                          AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]

    private var recorder: AVAudioRecorder?

    var seconds: Double { recorder?.currentTime ?? 0 }

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw RecordingProblem.microphoneDenied }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("debrief-\(UUID().uuidString).m4a")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: file, settings: Self.settings)
            guard recorder.record(forDuration: DebriefModel.limit) else { throw RecordingProblem.couldNotStart }
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                                   ofItemAtPath: file.path)
            self.recorder = recorder
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false)
            throw RecordingProblem.couldNotStart
        }
    }

    func stop() -> Recording? {
        guard let recorder else { return nil }
        let seconds = min(recorder.currentTime > 0 ? recorder.currentTime : DebriefModel.limit, DebriefModel.limit)
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return Recording(file: recorder.url, seconds: seconds)
    }

    func cancel() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
