import Foundation
import Observation

/// The notes review (#142, step 6.6.9; #152): for one transcribed debrief, code labels each sentence that was
/// said and writes the notes from them, word for word, and finds every heard number (checked against the pack);
/// no model. The officer decides each one, changes a label or tags a sentence code left, then saves.
@Observable @MainActor
final class DebriefReviewModel {
    enum Stage: Equatable {
        case drafting, review, noTranscript, alreadySaved
        case saved(count: Int)
    }

    /// One note as the page shows it.
    struct NoteLine: Identifiable, Equatable {
        let id: Int
        let kind: String
        let text: String
        let detail: String?
        let quote: String?
        let problems: [String]
        let canConfirm: Bool
        let decision: String?
        /// Written by code from a sentence (#152): its label can be changed.
        var fromSentence = false
    }

    /// One heard number as the page shows it.
    struct NumberLine: Identifiable, Equatable {
        let id: Int
        let heard: String
        let context: String
        let problems: [String]
        let decision: String?
        /// The pack's value, when the pack disagrees with what was heard.
        var suggestion: String?

        var suggestionWords: String? {
            suggestion.flatMap(Int.init).map { "Use \(InvoiceChecks.money($0)) (from the pack)" }
        }
    }

    let debrief: Debrief
    let mission: String
    private(set) var stage = Stage.drafting
    private(set) var review: DebriefReview
    private(set) var decisions = DebriefDecisions()
    private(set) var problem: String?
    /// The sentences code gave no label, for the officer to tag (#152).
    private(set) var untagged: [DebriefSentence] = []
    private var written: Set<Int> = []
    private var transcript = ""
    private let store: MissionStore
    private let contracts: PackContracts?

    init(mission: String, debrief: Debrief, store: MissionStore, contracts: PackContracts?) {
        (self.mission, self.debrief, self.store, self.contracts) = (mission, debrief, store, contracts)
        review = DebriefReview(debrief: debrief, notes: [], numbers: [])
    }

    /// For the app: the contracts come from the mission's pack, when it has them.
    static func load(mission: String, debrief: Debrief, store: MissionStore) -> DebriefReviewModel {
        DebriefReviewModel(mission: mission, debrief: debrief, store: store,
                           contracts: try? PackContracts.read(try store.packFile(PackContracts.path, in: mission)))
    }

    /// The notes code writes from the sentences, grounded, and every heard number, checked.
    func draft() async {
        stage = .drafting
        if (try? store.confirmedDebriefs(in: mission))?.contains(debrief.seq) == true {
            stage = .alreadySaved
            return
        }
        guard let transcript = (try? store.transcript(of: debrief.seq, in: mission)).flatMap({ $0 }) else {
            stage = .noTranscript
            return
        }
        let numbers = SpokenNumbers.check(SpokenNumbers.find(transcript.text), contracts: contracts)
        let drafted = CodeNotes.draft(transcript.text)
        self.transcript = transcript.text
        review = DebriefReview(debrief: debrief, notes: drafted.notes, numbers: numbers)
        untagged = drafted.untagged
        stage = .review
    }

    /// A sentence code left without a label becomes a note of the kind the officer chose, word for word.
    func tag(_ index: Int, as kind: DebriefNote.Kind) {
        guard untagged.indices.contains(index) else { return }
        let note = CodeNotes.note(untagged.remove(at: index), kind: kind, transcript: transcript)
        review = DebriefReview(debrief: debrief, notes: review.notes + [note], numbers: review.numbers)
    }

    /// The officer changes a sentence note's label; it stays the sentence, word for word, to decide again.
    func relabel(note index: Int, as kind: DebriefNote.Kind) {
        // A note the officer wrote has no place in the transcript, so only a sentence note is relabelled.
        guard review.notes.indices.contains(index), review.notes[index].found != nil else { return }
        var notes = review.notes
        let old = notes[index].note
        notes[index] = NoteCheck(note: DebriefNote(kind: kind, text: old.text, who: old.who, byWhen: old.byWhen,
                                                   quote: old.quote),
                                 found: notes[index].found, problems: notes[index].problems)
        review = DebriefReview(debrief: debrief, notes: notes, numbers: review.numbers)
        decisions.notes[index] = nil
    }

    func addNote(_ kind: DebriefNote.Kind, _ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        let note = DebriefNote(kind: kind, text: words, who: "", byWhen: "", quote: "")
        let written = NoteCheck(note: note, found: nil, problems: [])
        review = DebriefReview(debrief: debrief, notes: review.notes + [written], numbers: review.numbers)
        self.written.insert(review.notes.count - 1)
        decisions.notes[review.notes.count - 1] = .edit(words)
    }

    func decide(note index: Int, _ decision: NoteDecision) {
        guard review.notes.indices.contains(index) else { return }
        if decision == .confirm, review.notes[index].found == nil { return }
        if case .edit(let text) = decision, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problem = "Write the note before keeping it."
            return
        }
        decisions.notes[index] = decision
        problem = nil
    }

    func decide(number index: Int, _ decision: NumberDecision) {
        guard review.numbers.indices.contains(index) else { return }
        decisions.numbers[index] = decision
    }

    /// Keeps the officer's number when it is not empty.
    @discardableResult
    func correct(number index: Int, to typed: String) -> Bool {
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            problem = "Enter the number as it should be."
            return false
        }
        decide(number: index, .correct(value))
        problem = nil
        return true
    }

    func undo(note index: Int) { decisions.notes[index] = nil }
    func undo(number index: Int) { decisions.numbers[index] = nil }

    var notes: [NoteLine] {
        review.notes.enumerated().map { index, check in
            let note = check.note
            let who = note.who.isEmpty ? nil : "Who: \(note.who)"
            let byWhen = note.byWhen.isEmpty ? nil : "By when: \(note.byWhen)"
            let detail = [who, byWhen].compactMap { $0 }.joined(separator: " · ")
            let decision: String? = switch decisions.notes[index] {
            case .confirm: "Confirmed"
            case .edit(let text): written.contains(index) ? "Written by you" : "Edited: \(text)"
            case .remove: "Removed"
            case nil: nil
            }
            return NoteLine(id: index, kind: note.kind.rawValue.capitalized, text: note.text,
                            detail: detail.isEmpty ? nil : detail, quote: note.quote.isEmpty ? nil : "“\(note.quote)”",
                            problems: check.problems, canConfirm: check.found != nil, decision: decision,
                            fromSentence: check.found != nil && !written.contains(index))
        }
    }

    var numbers: [NumberLine] {
        review.numbers.enumerated().map { index, number in
            Self.line(number, index: index, decision: decisions.numbers[index])
        }
    }

    static func line(_ number: HeardNumber, index: Int, decision: NumberDecision?) -> NumberLine {
        let words: String? = switch decision {
        case .confirm: number.problems.isEmpty ? "Confirmed" : "Kept as heard"
        case .correct(let value): "Corrected to \(value)"
        case nil: nil
        }
        return NumberLine(id: index, heard: number.words + (number.unit.map { " \($0)" } ?? ""),
                          context: number.context, problems: number.problems, decision: words,
                          suggestion: number.expected)
    }

    var summary: String {
        let toCheck = review.notes.filter { !$0.problems.isEmpty }.count
            + review.numbers.filter { !$0.problems.isEmpty }.count
        let total = review.notes.count + review.numbers.count
        let decided = decisions.notes.count + decisions.numbers.count
        return "\(review.notes.count) note\(review.notes.count == 1 ? "" : "s") · \(review.numbers.count) number"
            + (review.numbers.count == 1 ? "" : "s") + (toCheck == 0 ? "" : " · \(toCheck) to check")
            + " · \(decided) of \(total) decided"
    }

    var canSave: Bool {
        stage == .review && decisions.notes.count == review.notes.count
            && decisions.numbers.count == review.numbers.count && review.notes.count + review.numbers.count > 0
    }

    func save() {
        guard canSave else { return }
        do {
            stage = .saved(count: try store.confirmDebrief(review, decisions: decisions, in: mission).count)
        } catch is MissionStore.NothingToSave {
            problem = "Nothing is left to save: every note was removed and no number was heard."
        } catch is MissionStore.AlreadyConfirmed {
            stage = .alreadySaved
        } catch {
            problem = "The notes could not be saved. Try again."
        }
    }
}
