import Foundation
import Observation

/// The Debrief page (#142): after the consent line, record the officer's voice debrief, with a timer, stopped
/// at 5 minutes. Spike #14 used about 2 minutes; 5 leaves room without letting the microphone run on.
@Observable @MainActor
final class DebriefModel {
    enum State: Equatable, Sendable {
        case idle, recording
        case recorded(seconds: Double)
        case problem(RecordingProblem)
    }

    static let limit: TimeInterval = 300
    /// How many bars show the voice, newest on the right.
    static let bars = 32

    /// "I record only myself, or people who agreed": nothing records until the officer says so (threat P02).
    var consent = false
    private(set) var state = State.idle
    private(set) var elapsed = "0:00 of 5:00"
    private(set) var recording: Recording?
    private(set) var levels = Array(repeating: 0.0, count: DebriefModel.bars)
    let recorder: any DebriefRecorder

    init(recorder: any DebriefRecorder = MicrophoneRecorder()) {
        self.recorder = recorder
    }

    var canRecord: Bool { consent && state != .recording }

    func record() async {
        guard canRecord else { return }
        do {
            try await recorder.start()
            recording = nil
            levels = Array(repeating: 0, count: Self.bars)
            state = .recording
            tick()
        } catch let problem as RecordingProblem {
            state = .problem(problem)
        } catch {
            state = .problem(.couldNotStart)
        }
    }

    /// Called about 12 times a second while recording (the page's timeline): the bars, the timer, and the
    /// stop at the limit.
    func tick() {
        guard state == .recording else { return }
        levels = Array((levels + [recorder.level]).suffix(Self.bars))
        let seconds = min(recorder.seconds, Self.limit)
        elapsed = "\(Self.clock(seconds)) of \(Self.clock(Self.limit))"
        if seconds >= Self.limit { stop() }
    }

    func stop() {
        guard state == .recording, let made = recorder.stop() else { return }
        recording = made
        state = .recorded(seconds: made.seconds)
        levels = Array(repeating: 0, count: Self.bars)
    }

    func cancel() {
        recorder.cancel()
        recording = nil
        state = .idle
        elapsed = "0:00 of 5:00"
        levels = Array(repeating: 0, count: Self.bars)
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}
