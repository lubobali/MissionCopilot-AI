import AVFoundation
import Foundation
import GRDB
import Speech

/// What Apple's speech engine heard in a debrief (#142), and which engine heard it.
struct DebriefTranscript: Codable, Sendable, Equatable {
    /// Apple's SpeechTranscriber (iOS 26), as proven on the iPhone in spike #14.
    static let engine = "apple-speechtranscriber-1"

    let text: String
    let engine: String
}

/// Why a debrief has no transcript yet, in words the officer can act on. Nothing is stored, so it can be tried
/// again.
enum TranscriptionProblem: Error, Equatable, Sendable {
    case nothingHeard, languageNotInstalled, failed

    var words: String {
        switch self {
        case .nothingHeard: "No words were heard. Record again, closer to the phone."
        case .languageNotInstalled:
            "This language's speech files are not on this iPhone. Install them in Before you go while online."
        case .failed: "The recording could not be turned into text. Try again."
        }
    }
}

/// Speech to text. The real one is Apple's, on the phone; tests use a fake.
protocol DebriefTranscriber: Sendable {
    func transcribe(_ audio: Data, language: SpeechLanguage) async throws -> String
}

/// Apple's SpeechTranscriber reading the recording from a file (final results only: a file gives no early
/// guesses), on the phone, offline. The sealed audio is opened into a temporary file with Complete protection
/// only for the reading, then deleted.
struct AppleTranscriber: DebriefTranscriber {
    var files: any SpeechFiles = AppleSpeechFiles()

    func transcribe(_ audio: Data, language: SpeechLanguage) async throws -> String {
        guard await files.status(of: language) == .installed else { throw TranscriptionProblem.languageNotInstalled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("read-\(UUID().uuidString).m4a")
        try audio.write(to: file, options: [.completeFileProtection])
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let transcriber = AppleSpeechFiles.transcriber(language)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let collected = Task {
                var text = ""
                for try await result in transcriber.results { text += String(result.text.characters) }
                return text
            }
            try await analyzer.start(inputAudioFile: try AVAudioFile(forReading: file), finishAfterFile: true)
            return try await collected.value
        } catch {
            throw TranscriptionProblem.failed
        }
    }
}

extension MissionStore {
    struct NotADebrief: Error {}

    /// The debrief's transcript: kept if it was read already, otherwise read now from its sealed recording, in
    /// its language, and stored sealed. Nothing heard or a failure stores nothing.
    func transcribe(_ debrief: Debrief, in mission: String, engine: any DebriefTranscriber,
                    now: Date = Date()) async throws -> DebriefTranscript {
        if let kept = try transcript(of: debrief.seq, in: mission) { return kept }
        guard try debriefs(in: mission).contains(where: { $0.seq == debrief.seq }) else { throw NotADebrief() }
        let heard: String
        do {
            heard = try await engine.transcribe(try evidenceFile(in: mission, seq: debrief.seq),
                                                language: debrief.language)
        } catch let problem as TranscriptionProblem {
            throw problem
        } catch {
            throw TranscriptionProblem.failed
        }
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionProblem.nothingHeard }
        let transcript = DebriefTranscript(text: text, engine: DebriefTranscript.engine)
        let sealed = try MissionData.seal(try JSONEncoder().encode(transcript), with: missionKey(for: mission))
        try store.write { database in
            try database.execute(sql: "INSERT INTO debrief_transcript VALUES (?, ?, ?, ?, ?)",
                                 arguments: [mission, debrief.seq, transcript.engine, sealed,
                                             now.timeIntervalSince1970])
            try EncryptedStore.appendAudit(AuditEntry(action: .debriefTranscribed, actor: actor, mission: mission,
                                                      target: "\(debrief.seq) \(transcript.engine)", time: now),
                                           in: database)
        }
        return transcript
    }

    /// The debrief's stored transcript by the current engine, or nil if it has not been read yet.
    func transcript(of seq: Int, in mission: String) throws -> DebriefTranscript? {
        let sealed = try store.read { database in
            try Data.fetchOne(database, sql: """
                SELECT sealed_text FROM debrief_transcript WHERE mission_id = ? AND evidence_seq = ? AND engine = ?
                """, arguments: [mission, seq, DebriefTranscript.engine])
        }
        guard let sealed else { return nil }
        return try JSONDecoder().decode(DebriefTranscript.self,
                                        from: try MissionData.open(sealed, with: missionKey(for: mission)))
    }
}
