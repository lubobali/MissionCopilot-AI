import Foundation
import Observation

/// The notes review (#142, step 6.6.9): for one transcribed debrief, the assistant drafts notes, code grounds
/// them and finds every heard number (checked against the pack); the officer decides each one, then saves.
@Observable @MainActor
final class DebriefReviewModel {
    enum Stage: Equatable {
        case drafting, review, noTranscript, alreadySaved
        case toOfficer(DebriefExtraction.Why)
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
    private var written: Set<Int> = []
    private let store: MissionStore
    private let contracts: PackContracts?
    private let model: FieldModel

    init(mission: String, debrief: Debrief, store: MissionStore, contracts: PackContracts?,
         model: FieldModel = AppModel.field) {
        (self.mission, self.debrief, self.store, self.contracts, self.model) = (mission, debrief, store, contracts,
                                                                                model)
        review = DebriefReview(debrief: debrief, notes: [], numbers: [])
    }

    /// For the app: the contracts come from the mission's pack, when it has them.
    static func load(mission: String, debrief: Debrief, store: MissionStore) -> DebriefReviewModel {
        DebriefReviewModel(mission: mission, debrief: debrief, store: store,
                           contracts: try? PackContracts.read(try store.packFile(PackContracts.path, in: mission)))
    }

    /// The assistant's notes, grounded, and every heard number, checked.
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
        switch await DebriefExtraction.extract(transcript.text, model: model) {
        case .notes(let notes):
            review = DebriefReview(debrief: debrief, notes: NoteGrounding.check(notes, transcript: transcript.text),
                                   numbers: numbers)
            stage = .review
        case .toOfficer(let why):
            review = DebriefReview(debrief: debrief, notes: [], numbers: numbers)
            stage = .toOfficer(why)
        }
    }

    /// The assistant could not help: the officer writes the notes (the numbers are still read back).
    func writeYourself() { stage = .review }

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
                            problems: check.problems, canConfirm: check.found != nil, decision: decision)
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
