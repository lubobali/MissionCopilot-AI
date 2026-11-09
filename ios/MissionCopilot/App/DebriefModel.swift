import Foundation
import Observation

/// The Debrief page (#142): after the consent line, record the officer's voice debrief, with a timer, stopped
/// at 5 minutes. Spike #14 used about 2 minutes; 5 leaves room without letting the microphone run on.
@Observable @MainActor
final class DebriefModel {
    /// #152: code writes the notes from the sentences said; a label said first makes a sentence a note.
    static let noteTip = "Start a sentence with “Action”, “Risk” or “Decision” to make it a note."

    enum State: Equatable, Sendable {
        case idle, recording
        case recorded(seconds: Double)
        case problem(RecordingProblem)
    }

    /// Where a kept debrief's text is: being read, read, or why not.
    enum TranscriptState: Equatable, Sendable {
        case reading
        case heard(String)
        case problem(TranscriptionProblem)

        var words: String {
            switch self {
            case .reading: "Turning the recording into text"
            case .heard(let text): text
            case .problem(let problem): problem.words
            }
        }
    }

    nonisolated static let limit: TimeInterval = 300
    /// How many bars show the voice, newest on the right.
    nonisolated static let bars = 32

    /// "I record only myself, or people who agreed": nothing records until the officer says so (threat P02).
    var consent = false
    private(set) var state = State.idle
    private(set) var elapsed = "0:00 of 5:00"
    /// The language the officer speaks; the transcript is read in it (6.6.3).
    var language = SpeechLanguage.english
    private(set) var debriefs: [Debrief] = []
    private(set) var transcripts: [Int: TranscriptState] = [:]
    /// Each read debrief's words the engine was not sure of (#153), underlined on its card.
    private(set) var unsure: [Int: [TextSpan]] = [:]
    /// Debriefs whose notes are saved (6.6.8).
    private(set) var confirmed: Set<Int> = []
    private(set) var levels = Array(repeating: 0.0, count: DebriefModel.bars)
    let recorder: any DebriefRecorder
    let mission: String
    private let store: MissionStore
    private let signer: any EvidenceSigner
    private let transcriber: any DebriefTranscriber

    init(mission: String, store: MissionStore,
         signer: any EvidenceSigner = SecureEnclaveEvidenceSigner(user: AppSession.localProfile),
         recorder: any DebriefRecorder = MicrophoneRecorder(),
         transcriber: any DebriefTranscriber = AppleTranscriber()) {
        (self.mission, self.store, self.signer, self.recorder) = (mission, store, signer, recorder)
        self.transcriber = transcriber
    }

    /// The debriefs kept for this mission, oldest first, each with its stored text if it has one.
    func load() {
        debriefs = (try? store.debriefs(in: mission)) ?? []
        confirmed = (try? store.confirmedDebriefs(in: mission)) ?? []
        for debrief in debriefs where transcripts[debrief.seq] == nil {
            if let kept = (try? store.transcript(of: debrief.seq, in: mission)).flatMap({ $0 }) {
                transcripts[debrief.seq] = .heard(kept.text)
                unsure[debrief.seq] = kept.unsure
            }
        }
    }

    func loadAndRead() async {
        load()
        await readWaiting()
    }

    /// Every kept debrief with no text yet is read now, one at a time (never twice at once).
    func readWaiting() async {
        for debrief in debriefs where transcripts[debrief.seq] == nil {
            await read(debrief)
        }
    }

    /// Tries a debrief whose text failed again.
    func retry(_ seq: Int) async {
        guard case .problem = transcripts[seq], let debrief = debriefs.first(where: { $0.seq == seq }) else { return }
        await read(debrief)
    }

    private func read(_ debrief: Debrief) async {
        transcripts[debrief.seq] = .reading
        do {
            let transcript = try await store.transcribe(debrief, in: mission, engine: transcriber)
            transcripts[debrief.seq] = .heard(transcript.text)
            unsure[debrief.seq] = transcript.unsure
        } catch let problem as TranscriptionProblem {
            transcripts[debrief.seq] = .problem(problem)
        } catch {
            transcripts[debrief.seq] = .problem(.failed)
        }
    }

    static func summary(_ debriefs: [Debrief]) -> String {
        guard !debriefs.isEmpty else { return DebriefCard.start }
        let total = debriefs.reduce(0) { $0 + $1.seconds }
        return "\(debriefs.count) debrief\(debriefs.count == 1 ? "" : "s") · \(clock(total))"
    }

    var summary: String { Self.summary(debriefs) }

    var canRecord: Bool { consent && state != .recording }

    func record() async {
        guard canRecord else { return }
        do {
            try await recorder.start()
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

    /// Stops, then keeps the recording as signed evidence at once (6.6.2).
    func stop() {
        guard state == .recording, let made = recorder.stop() else { return }
        do {
            try store.addDebrief(made, language: language, to: mission, signer: signer)
            load()
            state = .recorded(seconds: made.seconds)
        } catch {
            try? FileManager.default.removeItem(at: made.file)
            state = .problem(.notSaved)
        }
        levels = Array(repeating: 0, count: Self.bars)
    }

    func cancel() {
        recorder.cancel()
        state = .idle
        elapsed = "0:00 of 5:00"
        levels = Array(repeating: 0, count: Self.bars)
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}
