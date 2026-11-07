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
        var level: Double = 0
        var refuse: RecordingProblem?
        private(set) var started = 0
        private(set) var cancelled = 0
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("debrief-\(UUID().uuidString).m4a")

        func start() async throws {
            if let refuse { throw refuse }
            started += 1
        }

        func stop() -> Recording? {
            guard started > 0 else { return nil }
            try? Data("fake m4a audio".utf8).write(to: file)
            return Recording(file: file, seconds: seconds)
        }

        func cancel() { cancelled += 1 }
    }

    static func store() throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: "kandor-roads", title: "Kandor rural roads")
        return store
    }

    static func model(_ recorder: FakeRecorder, store: MissionStore? = nil) throws -> DebriefModel {
        DebriefModel(mission: "kandor-roads", store: try store ?? Self.store(), signer: SoftwareEvidenceSigner(),
                     recorder: recorder)
    }

    @Test func stoppingKeepsTheRecordingAsADebrief() async throws {
        let recorder = FakeRecorder()
        let store = try Self.store()
        let model = try Self.model(recorder, store: store)
        model.consent = true
        model.language = .french
        await model.record()
        recorder.seconds = 42

        model.stop()

        #expect(try store.debriefs(in: "kandor-roads").map(\.language) == [.french])
        #expect(model.debriefs == (try store.debriefs(in: "kandor-roads")))
        #expect(model.summary == "1 debrief · 0:42")
        let again = try Self.model(FakeRecorder(), store: store)
        again.load()
        #expect(again.debriefs.count == 1)
        #expect(DebriefModel.summary([]) == DebriefCard.start)
    }

    @Test func nothingIsRecordedBeforeTheConsentLine() async throws {
        let recorder = FakeRecorder()
        let model = try Self.model(recorder)

        await model.record()

        #expect(recorder.started == 0)
        #expect(model.state == .idle)
        #expect(!model.canRecord)
    }

    @Test func afterConsentItRecordsThenStops() async throws {
        let recorder = FakeRecorder()
        let model = try Self.model(recorder)
        model.consent = true
        #expect(model.canRecord)

        await model.record()
        #expect(model.state == .recording)
        recorder.seconds = 42
        model.tick()
        #expect(model.elapsed == "0:42 of 5:00")
        model.stop()

        #expect(model.state == .recorded(seconds: 42))
        #expect(model.debriefs.map(\.seconds) == [42])
    }

    @Test func itStopsByItselfAtFiveMinutes() async throws {
        let recorder = FakeRecorder()
        let model = try Self.model(recorder)
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

    @Test func aCancelledRecordingLeavesNothing() async throws {
        let recorder = FakeRecorder()
        let model = try Self.model(recorder)
        model.consent = true
        await model.record()

        model.cancel()

        #expect(recorder.cancelled == 1)
        #expect(model.state == .idle)
        #expect(model.debriefs.isEmpty)
    }

    @Test func aRefusedMicrophoneSaysWhereToTurnItOn() async throws {
        let recorder = FakeRecorder()
        recorder.refuse = .microphoneDenied
        let model = try Self.model(recorder)
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

    /// Found on the iPhone: a timer alone does not show the microphone hears you; bars move with the voice.
    @Test func theBarsFollowTheVoiceAndKeepTheLastFew() async throws {
        let recorder = FakeRecorder()
        let model = try Self.model(recorder)
        model.consent = true
        await model.record()
        #expect(model.levels == Array(repeating: 0, count: DebriefModel.bars))

        for loudness in [0.2, 0.9, 0.5] {
            recorder.level = loudness
            model.tick()
        }

        #expect(model.levels.count == DebriefModel.bars)
        #expect(Array(model.levels.suffix(3)) == [0.2, 0.9, 0.5])
        model.stop()
        #expect(model.levels.allSatisfy { $0 == 0 })
    }

    @Test func theMicrophoneLoudnessBecomesABarHeight() {
        #expect(MicrophoneRecorder.height(decibels: -160) == 0)  // silence
        #expect(MicrophoneRecorder.height(decibels: -50) == 0)
        #expect(MicrophoneRecorder.height(decibels: -25) == 0.5)
        #expect(MicrophoneRecorder.height(decibels: 0) == 1)
        #expect(MicrophoneRecorder.height(decibels: 6) == 1)
    }

    @Test func theTimeReadsInMinutesAndSeconds() {
        #expect(DebriefModel.clock(0) == "0:00")
        #expect(DebriefModel.clock(65.7) == "1:05")
        #expect(DebriefModel.clock(300) == "5:00")
    }
}
