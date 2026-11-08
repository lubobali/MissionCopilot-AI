import Foundation
import Observation

/// The Ask page (#145): a question finds the mission's sources on the phone, offline. PR 1 shows the sources
/// themselves; PR 2 adds an answer that cites them.
@Observable @MainActor
final class AskModel {
    enum State: Equatable { case waiting, found, nothingFound }

    /// One source found, in words.
    struct Result: Identifiable, Equatable {
        let id: String
        let title: String
        let kind: String
        let place: String
        let text: String
    }

    static let nothingFound = "Nothing in this mission's data matches this question."

    var question = ""
    private(set) var state = State.waiting
    private(set) var results: [Result] = []
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

    func ask() {
        guard canAsk else { return }
        results = search.search(question).map { hit in
            Result(id: hit.source.id, title: hit.source.title, kind: Self.kindWords(hit.source.kind),
                   place: Self.place(hit.source.origin), text: hit.source.text)
        }
        state = results.isEmpty ? .nothingFound : .found
    }

    static func kindWords(_ kind: MissionSource.Kind) -> String {
        switch kind {
        case .pack: "Bank record"
        case .document: "Document"
        case .fact: "Confirmed fact"
        case .note: "Debrief note"
        case .walkAnswer: "Site walk"
        case .redFlag: "Red flag"
        }
    }

    /// Where a source came from, in words: the pack file and field, the document and paragraph, the evidence.
    static func place(_ origin: SourceOrigin) -> String {
        switch origin {
        case .pack(let citation):
            "\(citation.path.split(separator: "/").last.map(String.init) ?? citation.path) · \(citation.pointer)"
        case .document(let path, let paragraph):
            "\(path.split(separator: "/").last.map(String.init) ?? path) · paragraph \(paragraph)"
        case .fact(_, let sources):
            "Evidence \(sources.map { String($0.seq) }.joined(separator: ", ")), confirmed by the officer"
        case .walk(let question): "Site walk · \(question)"
        case .redFlag(let rule): "Red flag rule \(rule)"
        }
    }
}
