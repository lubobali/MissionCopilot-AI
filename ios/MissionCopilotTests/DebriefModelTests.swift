import AVFoundation
import Foundation
import Testing
@testable import MissionCopilot

/// Recording a debrief (#142, step 6.6.1): only after the consent line, with a timer, stopped at 5 minutes;
/// a cancelled recording leaves nothing. The microphone is a fake here; the real one is proven on the iPhone.
@MainActor
struct DebriefModelTests {
    /// A microphone that records whatever length the test sets, and remembers what it was asked.
    final class FakeRecorder: DebriefRecorder {
        var seconds: Double = 0
        var refuse: RecordingProblem?
        private(set) var started = 0
        private(set) var cancelled = 0
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("debrief-\(UUID().uuidString).m4a")

        func start() async throws {
            if let refuse { throw refuse }
            started += 1
        }

        func stop() -> Recording? { started > 0 ? Recording(file: file, seconds: seconds) : nil }

        func cancel() { cancelled += 1 }
    }

    @Test func nothingIsRecordedBeforeTheConsentLine() async {
        let recorder = FakeRecorder()
        let model = DebriefModel(recorder: recorder)

        await model.record()

        #expect(recorder.started == 0)
        #expect(model.state == .idle)
        #expect(!model.canRecord)
    }

    @Test func afterConsentItRecordsThenStops() async {
        let recorder = FakeRecorder()
        let model = DebriefModel(recorder: recorder)
        model.consent = true
        #expect(model.canRecord)

        await model.record()
        #expect(model.state == .recording)
        recorder.seconds = 42
        model.tick()
        #expect(model.elapsed == "0:42 of 5:00")
        model.stop()

        #expect(model.state == .recorded(seconds: 42))
        #expect(model.recording == Recording(file: recorder.file, seconds: 42))
    }

    @Test func itStopsByItselfAtFiveMinutes() async {
        let recorder = FakeRecorder()
        let model = DebriefModel(recorder: recorder)
        model.consent = true
        await model.record()

        recorder.seconds = 299
        model.tick()
        #expect(model.state == .recording)
        recorder.seconds = 300
        model.tick()

        #expect(model.state == .recorded(seconds: 300))
        #expect(DebriefModel.limit == 300)
    }

    @Test func aCancelledRecordingLeavesNothing() async {
        let recorder = FakeRecorder()
        let model = DebriefModel(recorder: recorder)
        model.consent = true
        await model.record()

        model.cancel()

        #expect(recorder.cancelled == 1)
        #expect(model.state == .idle)
        #expect(model.recording == nil)
    }

    @Test func aRefusedMicrophoneSaysWhereToTurnItOn() async {
        let recorder = FakeRecorder()
        recorder.refuse = .microphoneDenied
        let model = DebriefModel(recorder: recorder)
        model.consent = true

        await model.record()

        #expect(model.state == .problem(.microphoneDenied))
        #expect(RecordingProblem.microphoneDenied.words
                == "The microphone is off for Mission Copilot. Turn it on in Settings, Mission Copilot.")
        #expect(RecordingProblem.couldNotStart.words == "The recording did not start. Try again.")
    }

    @Test func theRecordingIsSmallSpeechQualityAudio() {
        // Spike #14's format on this iPhone: AAC, 16 kHz, one channel, 32 kbit/s (about 1.2 MB for 5 minutes).
        #expect(MicrophoneRecorder.settings[AVFormatIDKey] as? Int == Int(kAudioFormatMPEG4AAC))
        #expect(MicrophoneRecorder.settings[AVSampleRateKey] as? Int == 16_000)
        #expect(MicrophoneRecorder.settings[AVNumberOfChannelsKey] as? Int == 1)
        #expect(MicrophoneRecorder.settings[AVEncoderBitRateKey] as? Int == 32_000)
    }

    @Test func theTimeReadsInMinutesAndSeconds() {
        #expect(DebriefModel.clock(0) == "0:00")
        #expect(DebriefModel.clock(65.7) == "1:05")
        #expect(DebriefModel.clock(300) == "5:00")
    }
}
