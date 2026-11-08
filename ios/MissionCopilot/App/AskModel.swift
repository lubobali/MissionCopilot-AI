import Foundation
import Observation

/// The Ask chat (#145): each question finds the mission's sources on the phone, offline, and becomes a message.
/// PR 1 shows the sources found as the reply; PR 2 turns them into a checked answer. The assistant keeps no
/// memory between questions: each reply is built and checked on its own.
@Observable @MainActor
final class AskModel {
    /// One question and its reply.
    struct Message: Identifiable, Equatable {
        let id: Int
        let question: String
        let cards: [SourceCardWords]
        var found: Bool { !cards.isEmpty }
    }

    static let nothingFound = "Nothing in this mission's data matches this question."
    static let examples = ["Was the Section 3 bridge started?", "How much has been paid?",
                           "What did the contractor promise in May?"]

    var question = ""
    private(set) var messages: [Message] = []
    private var next = 0
    private let search: MissionSearch
    private let sources: [MissionSource]

    init(sources: [MissionSource]) {
        search = MissionSearch(sources: sources)
        self.sources = sources
    }

    var canAsk: Bool { !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var summary: String {
        sources.isEmpty ? "No mission data on this iPhone yet" : "\(sources.count) sources on this iPhone"
    }

    /// Asks the typed question; the field empties for the next one.
    func ask() {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        messages.append(Message(id: next, question: asked, cards: SourceWords.group(search.search(asked))))
        next += 1
        question = ""
    }

    func ask(example: String) {
        question = example
        ask()
    }

    /// Empties the typed text in one tap.
    func clear() { question = "" }

    /// A clean conversation.
    func newChat() {
        messages = []
        question = ""
    }
}
