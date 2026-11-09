import AVFoundation
import Foundation
import GRDB
import Speech

/// What Apple's speech engine heard in a debrief (#142), which engine heard it, and the words it was not sure of.
struct DebriefTranscript: Codable, Sendable, Equatable {
    /// Apple's DictationTranscriber with the mission's names (#153, decided from Lubo's voice: 19% word errors
    /// against 29%, the invoice amount heard right).
    static let engine = "apple-dictation-names-1"
    /// The engines whose transcripts the app reads, newest first: spike #14's SpeechTranscriber kept the first ones.
    static let readable = [engine, "apple-speechtranscriber-1"]

    let text: String
    let engine: String
    /// Words under half confidence, for the officer to check (#153); none for the older engine.
    var unsure: [TextSpan] = []

    init(text: String, engine: String, unsure: [TextSpan] = []) {
        (self.text, self.engine, self.unsure) = (text, engine, unsure)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        engine = try container.decode(String.self, forKey: .engine)
        unsure = try container.decodeIfPresent([TextSpan].self, forKey: .unsure) ?? []
    }
}

/// What the engine heard: the text, and where the words it was not sure of are.
struct HeardText: Sendable, Equatable {
    static let unsureBelow = 0.5

    let text: String
    var unsure: [TextSpan] = []

    /// The engine's pieces with their confidence (nil: not given) as one text, each unsure word's place kept
    /// without the spaces around it.
    static func from(_ pieces: [(String, Double?)]) -> HeardText {
        var text = "", unsure: [TextSpan] = []
        for (piece, confidence) in pieces {
            if let confidence, confidence < unsureBelow {
                let leading = piece.prefix { $0.isWhitespace }.count
                let word = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !word.isEmpty { unsure.append(TextSpan(offset: text.count + leading, length: word.count)) }
            }
            text += piece
        }
        return HeardText(text: text, unsure: unsure)
    }
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
    /// The recording as text, read with the mission's names (#153), with the words the engine was not sure of.
    func transcribe(_ audio: Data, language: SpeechLanguage, names: [String]) async throws -> HeardText
}

/// Apple's DictationTranscriber reading the recording from a file with the mission's names as contextual strings
/// and each word's confidence (#153), final results only, on the phone, offline. The sealed audio is opened into
/// a temporary file with Complete protection only for the reading, then deleted.
struct AppleTranscriber: DebriefTranscriber {
    var files: any SpeechFiles = AppleSpeechFiles()

    func transcribe(_ audio: Data, language: SpeechLanguage, names: [String]) async throws -> HeardText {
        guard await files.status(of: language) == .installed else { throw TranscriptionProblem.languageNotInstalled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("read-\(UUID().uuidString).m4a")
        try audio.write(to: file, options: [.completeFileProtection])
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let transcriber = AppleSpeechFiles.transcriber(language)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(names.prefix(MissionNames.maxNames))
            try await analyzer.setContext(context)
            let collected = Task {
                var pieces: [(String, Double?)] = []
                for try await result in transcriber.results where result.isFinal {
                    for run in result.text.runs {
                        let words = String(result.text[run.range].characters)
                        pieces.append((words, run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]))
                    }
                }
                return HeardText.from(pieces)
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
        let heard: HeardText
        let names = MissionNames.from(packFiles: (try? packFiles(in: mission)) ?? [:])
        do {
            heard = try await engine.transcribe(try evidenceFile(in: mission, seq: debrief.seq),
                                                language: debrief.language, names: names)
        } catch let problem as TranscriptionProblem {
            throw problem
        } catch {
            throw TranscriptionProblem.failed
        }
        let text = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionProblem.nothingHeard }
        let cut = heard.text.prefix { $0.isWhitespace }.count  // spans follow the trimmed text
        let unsure = heard.unsure.map { TextSpan(offset: $0.offset - cut, length: $0.length) }
            .filter { $0.offset >= 0 && $0.offset + $0.length <= text.count }
        let transcript = DebriefTranscript(text: text, engine: DebriefTranscript.engine, unsure: unsure)
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

    /// The debrief's stored transcript, or nil if it has not been read yet. A debrief is read once (transcribe
    /// returns the kept one), so one read before #153 keeps its first transcript: its saved notes point into it.
    func transcript(of seq: Int, in mission: String) throws -> DebriefTranscript? {
        let readable = DebriefTranscript.readable
        let sealed = try store.read { database in
            try Data.fetchOne(database, sql: """
                SELECT sealed_text FROM debrief_transcript WHERE mission_id = ? AND evidence_seq = ? AND engine IN \
                (\(readable.map { _ in "?" }.joined(separator: ", "))) LIMIT 1
                """, arguments: StatementArguments([mission, seq] as [any DatabaseValueConvertible] + readable))
        }
        guard let sealed else { return nil }
        return try JSONDecoder().decode(DebriefTranscript.self,
                                        from: try MissionData.open(sealed, with: missionKey(for: mission)))
    }
}
