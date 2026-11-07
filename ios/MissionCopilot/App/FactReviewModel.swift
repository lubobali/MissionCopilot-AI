import Foundation
import Observation

/// The review page (#138, step 6.5.11): the read pages whose facts are not stored yet go through the
/// assistant and the checks; the officer confirms or corrects each of the 8 facts, then saves them.
@Observable @MainActor
final class FactReviewModel {
    enum Stage: Equatable {
        case reading, noPages, review
        case toOfficer(ScanExtraction.Why)
        case saved(Int)
    }

    /// One fact as the page shows it.
    struct Line: Equatable, Identifiable {
        let field: String
        let name: String
        let value: String
        let found: String
        let problems: [String]
        let canConfirm: Bool
        let decision: String?
        var id: String { field }
    }

    private(set) var stage = Stage.reading
    private(set) var review = FactReview(facts: .blank, printedAt: [:], problems: [])
    private(set) var decisions: [String: FactDecision] = [:]
    private(set) var problem: String?
    private(set) var manual = false
    private var pages: [Int] = []
    let mission: String
    private let store: MissionStore
    private let contracts: PackContracts?
    private let model: FieldModel

    init(mission: String, store: MissionStore, contracts: PackContracts?, model: FieldModel = AppModel.field) {
        (self.mission, self.store, self.contracts, self.model) = (mission, store, contracts, model)
    }

    /// For the app: the contracts come from the mission's pack, when it has them.
    static func load(mission: String, store: MissionStore) -> FactReviewModel {
        FactReviewModel(mission: mission, store: store,
                        contracts: try? PackContracts.read(try store.packFile(PackContracts.path, in: mission)))
    }

    /// The read pages not confirmed yet, in scan order, through the assistant and then every check.
    func read() async {
        stage = .reading
        let confirmed = (try? store.confirmedPages(in: mission)) ?? []
        let waiting = ((try? store.scans(in: mission)) ?? []).flatMap(\.pages).filter { !confirmed.contains($0) }
            .compactMap { seq in (try? store.reading(of: seq, in: mission)).flatMap { $0 }.map { (seq, $0) } }
        guard !waiting.isEmpty else {
            stage = .noPages
            return
        }
        pages = waiting.map(\.0)
        switch await ScanExtraction.extract(waiting.map(\.1), model: model) {
        case .read(let facts):
            review = InvoiceChecks.review(facts, pages: waiting.map(\.1),
                                          bank: contracts?.bankView(invoice: facts.invoiceNumber))
            stage = .review
        case .toOfficer(let why):
            stage = .toOfficer(why)
        }
    }

    /// The assistant could not answer: the officer types every fact from the pages.
    func enterYourself() {
        review = FactReview(facts: .blank, printedAt: [:], problems: [])
        manual = true
        stage = .review
    }

    var lines: [Line] {
        InvoiceFacts.fields.map { field in
            let printed = manual ? nil : review.printedAt[field]
            let missing = "Not found on the pages. Correct it to keep it."
            let found = manual ? "Read it on the scanned pages."
                : printed.map { "Page \($0.page + 1): “\($0.text)”" } ?? missing
            let decision: String? = switch decisions[field] {
            case .confirm: "Confirmed"
            case .correct(let value): "Corrected to " + InvoiceFacts.words(field, value: value)
            case nil: nil
            }
            return Line(field: field, name: InvoiceFacts.name(field),
                        value: manual ? "Enter it from the page"
                            : InvoiceFacts.words(field, value: review.facts.value(field) ?? ""),
                        found: found, problems: review.problems(for: field).map(\.words), canConfirm: printed != nil,
                        decision: decision)
        }
    }

    var summary: String {
        let toCheck = Set(review.problems.map(\.field)).count
        return "8 facts" + (toCheck == 0 ? "" : " · \(toCheck) to check")
            + " · \(decisions.count) of 8 decided"
    }

    var canSave: Bool { stage == .review && decisions.count == InvoiceFacts.fields.count }

    func confirm(_ field: String) {
        guard lines.first(where: { $0.field == field })?.canConfirm == true else { return }
        decisions[field] = .confirm
        problem = nil
    }

    /// Keeps the officer's value when it fits its field; otherwise says how to write it.
    @discardableResult
    func correct(_ field: String, to typed: String) -> Bool {
        guard let value = InvoiceFacts.corrected(field, typed: typed) else {
            problem = InvoiceFacts.hint(field)
            return false
        }
        decisions[field] = .correct(value)
        problem = nil
        return true
    }

    func undo(_ field: String) { decisions[field] = nil }

    func save() {
        guard canSave else { return }
        do {
            let facts = try store.confirmFacts(review, decisions: decisions, pages: pages, in: mission)
            stage = .saved(facts.count)
        } catch is MissionStore.AlreadyConfirmed {
            problem = "The facts of these pages are already saved."
        } catch {
            problem = "The facts could not be saved. Try again."
        }
    }
}
