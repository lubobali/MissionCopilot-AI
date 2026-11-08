import Foundation

/// One note the model drafts from a debrief (#142): a decision, an action (who, what, by when) or a risk, with
/// the exact words of the transcript it came from. Code checks every note; the officer confirms it.
struct DebriefNote: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable { case decision, action, risk }

    let kind: Kind
    let text: String
    /// Who will do it, as said; empty when not said.
    let who: String
    /// By when, as said ("by Friday"); never turned into a date by guessing. Empty when not said.
    let byWhen: String
    /// The exact words of the debrief the note comes from.
    let quote: String

    static let maxNotes = 10

    /// The grammar the model must fit: up to 10 notes, every field, nothing more.
    static let schema = #"""
        {"type":"object","additionalProperties":false,"required":["notes"],"properties":{"notes":{"type":"array",\#
        "maxItems":10,"items":{"type":"object","additionalProperties":false,\#
        "required":["kind","text","who","byWhen","quote"],"properties":{\#
        "kind":{"type":"string","enum":["decision","action","risk"]},"text":{"type":"string"},\#
        "who":{"type":"string"},"byWhen":{"type":"string"},"quote":{"type":"string"}}}}}}
        """#
}

/// A debrief's transcript to notes (#142, step 6.6.5), through the one model door. Only a schema-valid answer
/// within the time limit comes back as notes, still unchecked; everything else goes to the officer.
enum DebriefExtraction {
    enum Outcome: Equatable, Sendable {
        case notes([DebriefNote])
        case toOfficer(Why)
    }

    /// Why the officer writes the notes instead of the model.
    enum Why: Equatable, Sendable {
        case noText, tooLong(characters: Int), stopped, notUsable, noNotes
        case unavailable(ModelUnavailable)

        var words: String {
            switch self {
            case .noText: "This debrief has no text yet."
            case .tooLong(let characters):
                "This debrief has \(characters.formatted()) characters, too many for the assistant. "
                    + "Record a shorter debrief, or write the notes yourself."
            case .stopped: "The assistant did not answer within 20 s, so it stopped. Write the notes yourself."
            case .notUsable: "The assistant answered in a shape the app cannot use. Write the notes yourself."
            case .noNotes: "The assistant found no decision, action or risk. Write the notes yourself."
            case .unavailable(.notInThisBuild): "The assistant is not in this build. Write the notes yourself."
            case .unavailable(.failedCheck):
                "The assistant failed its safety check, so it stays off. Write the notes yourself."
            case .unavailable(.couldNotLoad):
                "The assistant could not start. Close other apps and try again, or write the notes yourself."
            }
        }
    }

    static func task(_ transcript: String) -> ModelTask<NotesAnswer> {
        ModelTask(prompt: """
            Turn this voice debrief into short mission notes as JSON. Each note is a decision, an action (who does \
            what, by when) or a risk. In quote, copy the exact words of the debrief the note comes from. Use only \
            what was said: leave who or byWhen empty when it was not said, and never add a date. At most 10 notes. \
            The debrief follows.

            \(transcript)
            """, schema: DebriefNote.schema, maxTokens: 512)
    }

    static func extract(_ transcript: String, model: FieldModel) async -> Outcome {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .toOfficer(.noText) }
        switch await model.run(task(text)) {
        case .answered(let answer):
            let notes = Array(answer.notes.prefix(DebriefNote.maxNotes))
            return notes.isEmpty ? .toOfficer(.noNotes) : .notes(notes)
        case .stopped: return .toOfficer(.stopped)
        case .refused(.inputTooLong(let characters)): return .toOfficer(.tooLong(characters: characters))
        case .refused(.unavailable(let why)): return .toOfficer(.unavailable(why))
        case .refused(.notSchemaValid), .refused(.failed): return .toOfficer(.notUsable)
        }
    }
}

/// The model's answer: the notes, before any check.
struct NotesAnswer: Decodable, Sendable { let notes: [DebriefNote] }
