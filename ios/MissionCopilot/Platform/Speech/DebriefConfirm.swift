import Foundation
import GRDB

/// The officer's decision on one drafted note (#142, step 6.6.8).
enum NoteDecision: Equatable, Sendable {
    case confirm
    case edit(String)
    case remove
}

/// The officer's decision on one heard number.
enum NumberDecision: Equatable, Sendable {
    case confirm
    case correct(String)
}

/// A note as stored: its words, who and by when (the kind is in the fact's name).
struct NoteValue: Codable, Sendable, Equatable {
    let text: String
    let who: String
    let byWhen: String
}

/// What the officer reviews for one debrief: its drafted notes after grounding, and its heard numbers.
struct DebriefReview: Sendable, Equatable {
    let debrief: Debrief
    let notes: [NoteCheck]
    let numbers: [HeardNumber]
}

/// The officer's decisions, by position in the review.
struct DebriefDecisions: Sendable, Equatable {
    var notes: [Int: NoteDecision] = [:]
    var numbers: [Int: NumberDecision] = [:]
}

extension TextSpan {
    /// Where in the sealed transcript: the engine that heard it, then the position and length. Never the words.
    var region: String { "\(DebriefTranscript.engine) text \(offset)+\(length)" }
}

extension MissionStore {
    struct DebriefNotDecided: Error, Equatable {
        let notes: [Int]
        let numbers: [Int]
    }

    struct CannotConfirmNote: Error, Equatable { let index: Int }
    struct CannotConfirmNumber: Error, Equatable { let index: Int }
    struct NothingToSave: Error {}

    static let debriefRule = RuleRef(id: "debrief", version: "1")

    /// Stores the debrief's notes and numbers once the officer decided every one, all in one write.
    @discardableResult
    func confirmDebrief(_ review: DebriefReview, decisions: DebriefDecisions, in mission: String,
                        now: Date = Date()) throws -> [Fact] {
        let undecided = DebriefNotDecided(notes: review.notes.indices.filter { decisions.notes[$0] == nil },
                                          numbers: review.numbers.indices.filter { decisions.numbers[$0] == nil })
        guard undecided.notes.isEmpty, undecided.numbers.isEmpty else { throw undecided }
        let notes = try review.notes.indices.compactMap { index in
            try noteInput(review.notes[index], decision: decisions.notes[index] ?? .remove, index: index,
                          debrief: review.debrief)
        }
        let numbers = try review.numbers.indices.map { index in
            try numberInput(review.numbers[index], decision: decisions.numbers[index] ?? .confirm, index: index,
                            debrief: review.debrief)
        }
        guard !(notes + numbers).isEmpty else { throw NothingToSave() }
        guard !(try confirmedDebriefs(in: mission)).contains(review.debrief.seq) else { throw AlreadyConfirmed() }
        return try addFacts(notes + numbers, to: mission, now: now)
    }

    /// A confirmed note cites its quote's place; an edited one is the officer's; a removed one is not stored.
    private func noteInput(_ check: NoteCheck, decision: NoteDecision, index: Int,
                           debrief: Debrief) throws -> FactInput? {
        let note = check.note
        var (text, rule) = (note.text, Self.debriefRule)
        switch decision {
        case .remove: return nil
        case .confirm:
            guard check.found != nil else { throw CannotConfirmNote(index: index) }
        case .edit(let typed):
            text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw CannotConfirmNote(index: index) }
            rule = Self.officerRule
        }
        let json = try JSONEncoder.sorted.encode(NoteValue(text: text, who: note.who, byWhen: note.byWhen))
        return FactInput(name: "debrief.\(note.kind.rawValue)", value: String(bytes: json, encoding: .utf8) ?? "",
                         unit: nil, sources: [FactSource(seq: debrief.seq, region: check.found?.region)], rule: rule)
    }

    /// A confirmed number keeps what was heard; a corrected one is the officer's value, with the heard unit.
    private func numberInput(_ number: HeardNumber, decision: NumberDecision, index: Int,
                             debrief: Debrief) throws -> FactInput {
        var (value, rule) = (number.value, Self.debriefRule)
        if case .correct(let typed) = decision {
            value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw CannotConfirmNumber(index: index) }
            rule = Self.officerRule
        }
        return FactInput(name: "spoken.\(number.kind.rawValue)", value: value, unit: number.unit,
                         sources: [FactSource(seq: debrief.seq, region: number.found.region)], rule: rule)
    }

    /// The debriefs whose notes and numbers are already stored.
    func confirmedDebriefs(in mission: String) throws -> Set<Int> {
        Set(try store.read { database in
            try Int.fetchAll(database, sql: """
                SELECT DISTINCT fact_source.evidence_seq FROM fact_source JOIN fact ON fact.id = fact_source.fact_id
                JOIN debrief ON debrief.mission_id = fact.mission_id AND debrief.evidence_seq = fact_source.evidence_seq
                WHERE fact.mission_id = ? AND fact.rule_id IN (?, ?)
                """, arguments: [mission, Self.debriefRule.id, Self.officerRule.id])
        })
    }
}

extension JSONEncoder {
    /// Keys in a fixed order, so the same note always stores the same text.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
