import Foundation
import GRDB

/// The officer's decision on one scanned fact (#138, step 6.5.9).
enum FactDecision: Equatable, Sendable {
    case confirm
    case correct(String)
}

extension PrintedAt {
    /// Where in the sealed reading: the reader that read the page, then the position and length of the words
    /// in that page's text (FactGrounding.text). A position, never the text itself.
    var region: String { "\(PageReading.currentReader) text \(offset)+\(text.count)" }
}

extension FactGrounding {
    /// The words a region points at in a page's reading; nil for another reader or a position not in the text.
    static func printed(_ region: String, in reading: PageReading) -> String? {
        let parts = region.split(separator: " ")
        guard parts.count == 3, parts[0] == reading.reader, parts[1] == "text" else { return nil }
        let numbers = parts[2].split(separator: "+").compactMap { Int($0) }
        let text = text(reading)
        guard numbers.count == 2, numbers[0] >= 0, numbers[1] > 0, numbers[0] + numbers[1] <= text.count else {
            return nil
        }
        let start = text.index(text.startIndex, offsetBy: numbers[0])
        return String(text[start..<text.index(start, offsetBy: numbers[1])])
    }
}

extension MissionStore {
    struct FactsNotDecided: Error, Equatable { let fields: [String] }
    struct CannotConfirm: Error, Equatable { let field: String }
    struct AlreadyConfirmed: Error, Equatable {}

    static let scanRule = RuleRef(id: "scan-invoice", version: "1")
    static let officerRule = RuleRef(id: "officer", version: "1")

    /// Stores the invoice's 8 facts once the officer decided every one; `pages` are the scanned pages' evidence
    /// seqs, in the order the review read them. All are stored in one write, or none.
    @discardableResult
    func confirmFacts(_ review: FactReview, decisions: [String: FactDecision], pages: [Int], in mission: String,
                      now: Date = Date()) throws -> [Fact] {
        let undecided = InvoiceFacts.fields.filter { decisions[$0] == nil }
        guard undecided.isEmpty else { throw FactsNotDecided(fields: undecided) }
        let inputs = try InvoiceFacts.fields.map { field in
            try input(field, review: review, decision: decisions[field] ?? .confirm, pages: pages)
        }
        let taken = try store.read { database in
            try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM fact_source JOIN fact ON fact.id = fact_source.fact_id
                WHERE fact.mission_id = ? AND fact.rule_id IN (?, ?) AND fact_source.evidence_seq IN (\(
                    pages.map { _ in "?" }.joined(separator: ", ")))
                """, arguments: StatementArguments([mission, Self.scanRule.id, Self.officerRule.id] + pages)) ?? 0
        }
        guard taken == 0 else { throw AlreadyConfirmed() }
        return try addFacts(inputs, to: mission, now: now)
    }

    private func input(_ field: String, review: FactReview, decision: FactDecision, pages: [Int]) throws -> FactInput {
        let unit = ["amountDue": "USD", "cumulativePaid": "USD", "contractValue": "USD", "kmCompleted": "km",
                    "kmTotal": "km"][field]
        switch decision {
        case .confirm:
            guard let printed = review.printedAt[field], pages.indices.contains(printed.page),
                  let value = review.facts.value(field) else { throw CannotConfirm(field: field) }
            return FactInput(name: field, value: value, unit: unit,
                             sources: [FactSource(seq: pages[printed.page], region: printed.region)],
                             rule: Self.scanRule)
        case .correct(let typed):
            let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !pages.isEmpty else { throw CannotConfirm(field: field) }
            return FactInput(name: field, value: value, unit: unit,
                             sources: pages.map { FactSource(seq: $0, region: nil) }, rule: Self.officerRule)
        }
    }
}

extension InvoiceFacts {
    /// A field's value as stored: whole numbers without commas, dates as YYYY-MM-DD.
    func value(_ field: String) -> String? {
        ["invoiceNumber": invoiceNumber, "invoiceDate": invoiceDate, "amountDue": String(amountDue),
         "cumulativePaid": String(cumulativePaid), "contractValue": String(contractValue),
         "kmCompleted": String(kmCompleted), "kmTotal": String(kmTotal), "bridgeStatus": bridgeStatus][field]
    }
}
