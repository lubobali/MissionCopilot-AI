import Foundation
import GRDB

/// The officer's decision on one scanned fact (#138, step 6.5.9).
enum FactDecision: Equatable, Sendable {
    case confirm
    /// A value typed by the officer that is not on the scanned pages (#151: only after a second tap).
    case correct(String)
    /// A value typed by the officer and found on a scanned page, with where (#151).
    case correctOnPage(String, PrintedAt)
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
        case .correctOnPage(let value, let printed):
            guard pages.indices.contains(printed.page) else { throw CannotConfirm(field: field) }
            return FactInput(name: field, value: value, unit: unit,
                             sources: [FactSource(seq: pages[printed.page], region: printed.region)],
                             rule: Self.officerRule)
        case .correct(let typed):
            let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !pages.isEmpty else { throw CannotConfirm(field: field) }
            return FactInput(name: field, value: value, unit: unit,
                             sources: pages.map { FactSource(seq: $0, region: nil) }, rule: Self.officerRule)
        }
    }
}

extension Fact {
    /// A scanned invoice's fact the officer typed and the pages do not show (#151): their word, not the page's.
    var typedNotOnPage: Bool {
        rule == MissionStore.officerRule && InvoiceFacts.fields.contains(name)
            && sources.allSatisfy { $0.region == nil }
    }
}

extension InvoiceFacts {
    /// The same facts with one field's stored value replaced; nil when the value does not fit the field.
    func replacing(_ field: String, with value: String) -> InvoiceFacts? {
        var all = Dictionary(uniqueKeysWithValues: InvoiceFacts.fields.map { ($0, self.value($0) ?? "") })
        all[field] = value
        let number = { (name: String) in Int(all[name] ?? "") }
        guard let due = number("amountDue"), let paid = number("cumulativePaid"), let total = number("contractValue"),
              let built = number("kmCompleted"), let length = number("kmTotal") else { return nil }
        return InvoiceFacts(invoiceNumber: all["invoiceNumber"] ?? "", invoiceDate: all["invoiceDate"] ?? "",
                            amountDue: due, cumulativePaid: paid, contractValue: total, kmCompleted: built,
                            kmTotal: length, bridgeStatus: all["bridgeStatus"] ?? "")
    }

    /// A field's value as stored: whole numbers without commas, dates as YYYY-MM-DD.
    func value(_ field: String) -> String? {
        ["invoiceNumber": invoiceNumber, "invoiceDate": invoiceDate, "amountDue": String(amountDue),
         "cumulativePaid": String(cumulativePaid), "contractValue": String(contractValue),
         "kmCompleted": String(kmCompleted), "kmTotal": String(kmTotal), "bridgeStatus": bridgeStatus][field]
    }
}

extension MissionStore {
    /// The scanned pages whose facts are already stored (by the scan rule or the officer).
    func confirmedPages(in mission: String) throws -> Set<Int> {
        Set(try store.read { database in
            try Int.fetchAll(database, sql: """
                SELECT DISTINCT fact_source.evidence_seq FROM fact_source JOIN fact ON fact.id = fact_source.fact_id
                WHERE fact.mission_id = ? AND fact.rule_id IN (?, ?)
                """, arguments: [mission, Self.scanRule.id, Self.officerRule.id])
        })
    }
}
