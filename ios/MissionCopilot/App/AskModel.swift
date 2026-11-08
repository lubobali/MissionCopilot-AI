import Foundation
import Observation

/// Where the chat keeps its questions and answers: the mission's sealed log on the phone (6.7.7), or memory
/// for previews and tests.
struct AskKeeper {
    let keep: @MainActor (AskResult) throws -> AskRecord
    let history: @MainActor () throws -> [AskRecord]

    @MainActor
    static func store(_ store: MissionStore, mission: String) -> AskKeeper {
        AskKeeper(keep: { try store.keepAnswer($0, in: mission) }, history: { try store.askHistory(in: mission) })
    }

    /// Kept in memory only, newest first (previews and tests).
    @MainActor
    static func memory(now: @escaping () -> Date = Date.init) -> AskKeeper {
        final class Box { var records: [AskRecord] = [] }
        let box = Box()
        return AskKeeper(keep: { result in
            let record = AskRecord(result, language: AskRecord.language(of: result.question), askedAt: now())
            box.records.insert(record, at: 0)
            return record
        }, history: { box.records })
    }
}

/// The Ask chat (#145): each question is searched in the mission's sources on the phone, answered through
/// the one model door, checked by code, kept in the sealed log, and shown as it was kept. Follow-ups give the
/// model the officer's earlier questions in this chat, never its earlier answers. New chat starts a clean
/// conversation; the history stays.
@Observable @MainActor
final class AskModel {
    /// One question and its reply: nil while the assistant works.
    struct Message: Identifiable, Equatable {
        let id: Int
        let question: String
        var record: AskRecord?
        /// The log refused it (rare): shown, but not in History.
        var notKept = false
        var thinking: Bool { record == nil }
    }

    static let examples = ["Was the Section 3 bridge started?", "How much has been paid?",
                           "What did the contractor promise in May?"]

    var question = ""
    private(set) var messages: [Message] = []
    private(set) var history: [AskRecord] = []
    private(set) var busy = false
    private var next = 0
    private let answerer: MissionAnswerer
    private let keeper: AskKeeper
    private let sourceCount: Int

    init(sources: [MissionSource], model: FieldModel = AppModel.field, keeper: AskKeeper = .memory()) {
        answerer = MissionAnswerer(search: MissionSearch(sources: sources), model: model)
        self.keeper = keeper
        sourceCount = sources.count
        history = (try? keeper.history()) ?? []
    }

    var canAsk: Bool { !busy && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var summary: String {
        sourceCount == 0 ? "No mission data on this iPhone yet" : "\(sourceCount) sources on this iPhone"
    }

    /// Asks the typed question; the field empties for the next one.
    func send() async {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !busy else { return }
        question = ""
        await answer(asked, earlier: messages.map(\.question))
    }

    func send(example: String) async {
        question = example
        await send()
    }

    /// A kept question asked again from History: a fresh answer on today's sources, kept as a new entry; the
    /// old one stays as it was. It starts fresh, without the questions of the chat on screen.
    func askAgain(_ record: AskRecord) async {
        guard !busy else { return }
        await answer(record.question, earlier: [])
    }

    /// Empties the typed text in one tap.
    func clear() { question = "" }

    /// A clean conversation; the kept questions stay in History.
    func newChat() {
        guard !busy else { return }
        messages = []
        question = ""
    }

    private func answer(_ asked: String, earlier: [String]) async {
        busy = true
        let id = next
        next += 1
        messages.append(Message(id: id, question: asked))
        let result = await answerer.answer(asked, earlier: earlier)
        var record: AskRecord, kept = true
        do {
            record = try keeper.keep(result)
        } catch {
            record = AskRecord(result, language: AskRecord.language(of: asked), askedAt: Date())
            kept = false
        }
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].record = record
            messages[index].notKept = !kept
        }
        history = (try? keeper.history()) ?? history
        busy = false
    }
}
