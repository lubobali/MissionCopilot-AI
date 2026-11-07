import Foundation

/// One reason a scanned fact goes to the officer, with its field and why in words (#138, step 6.5.8).
struct FactProblem: Equatable, Sendable {
    enum Check: String, CaseIterable, Sendable {
        case ungrounded, secondOpinion, impossibleValue, rowSum, invoiceRow, bankRecord, contractRemaining
        case contractPeriod
    }

    let field: String
    let check: Check
    let words: String
}

/// The model's facts after every check: where each is printed, and every problem found.
struct FactReview: Equatable, Sendable {
    let facts: InvoiceFacts
    let printedAt: [String: PrintedAt]
    let problems: [FactProblem]

    func problems(for field: String) -> [FactProblem] { problems.filter { $0.field == field } }
}

extension InvoiceFacts {
    /// The officer's name for each field.
    static func name(_ field: String) -> String {
        ["invoiceNumber": "Invoice number", "invoiceDate": "Invoice date", "amountDue": "Amount due",
         "cumulativePaid": "Paid to date", "contractValue": "Contract value", "kmCompleted": "Road built",
         "kmTotal": "Road length", "bridgeStatus": "Section 3 bridge"][field] ?? field
    }
}

/// Cross-checks by code (spikes #8 and #15): grounding catches a value the page does not print; these catch
/// a value an attacker printed, where grounding alone passes because the planted value is really there.
enum InvoiceChecks {
    static func review(_ facts: InvoiceFacts, pages: [PageReading], bank: InvoiceBankView?) -> FactReview {
        let printedAt = FactGrounding.sources(facts, in: pages)
        var problems = InvoiceFacts.fields.filter { printedAt[$0] == nil }
            .map { FactProblem(field: $0, check: .ungrounded, words: "Not found on the scanned pages.") }
        let opinion = FactGrounding.secondOpinion(facts, in: pages)
        let model = ["amountDue": money(facts.amountDue), "cumulativePaid": money(facts.cumulativePaid),
                     "contractValue": money(facts.contractValue), "invoiceDate": facts.invoiceDate,
                     "kmCompleted": String(facts.kmCompleted), "kmTotal": String(facts.kmTotal)]
        problems += InvoiceFacts.fields.compactMap { field in
            opinion[field].map { read in
                let labels = read.contains(" or ") ? "labels say" : "label says"
                return FactProblem(field: field, check: .secondOpinion,
                                   words: "The page's \(labels) \(read); the assistant read \(model[field] ?? "").")
            }
        }
        problems += impossibleValues(facts) + againstItsTable(facts, pages: pages)
        problems += bank.map { againstTheBank(facts, bank: $0) } ?? [
            FactProblem(field: "contractValue", check: .bankRecord,
                        words: "The mission pack has no contract to check it against.")
        ]
        let order = Dictionary(uniqueKeysWithValues: InvoiceFacts.fields.enumerated().map { ($1, $0) })
        return FactReview(facts: facts, printedAt: printedAt,
                          problems: problems.enumerated().sorted {
                              (order[$0.element.field] ?? 0, $0.offset) < (order[$1.element.field] ?? 0, $1.offset)
                          }.map(\.element))
    }

    /// No amount or distance below zero, and no more road built than exists.
    static func impossibleValues(_ facts: InvoiceFacts) -> [FactProblem] {
        let values = [("amountDue", facts.amountDue), ("cumulativePaid", facts.cumulativePaid),
                      ("contractValue", facts.contractValue), ("kmCompleted", facts.kmCompleted),
                      ("kmTotal", facts.kmTotal)]
        var found = values.filter { $0.1 < 0 }
            .map { FactProblem(field: $0.0, check: .impossibleValue, words: "Cannot be below zero.") }
        if facts.kmTotal >= 0, facts.kmCompleted > facts.kmTotal {
            found.append(FactProblem(field: "kmCompleted", check: .impossibleValue,
                                     words: "More road built than the road's length."))
        }
        return found
    }

    /// The page against itself: its payment table adds up to "paid to date", and holds the invoice's own row.
    static func againstItsTable(_ facts: InvoiceFacts, pages: [PageReading]) -> [FactProblem] {
        let rowSum = { (words: String) in FactProblem(field: "cumulativePaid", check: .rowSum, words: words) }
        guard let table = paymentTable(in: pages) else {
            return [rowSum("No payment table was read, so it could not be added up.")]
        }
        var found: [FactProblem] = []
        let amounts = table.rows.map { $0.count > table.amount ? parseAmount($0[table.amount]) : nil }
        let total = amounts.compactMap { $0 }.reduce(0, +)
        if let row = amounts.firstIndex(of: nil) {
            found.append(rowSum("Row \(row + 1) of the payment table cannot be read as a number."))
        } else if total != facts.cumulativePaid {
            found.append(rowSum("The payment table adds up to \(money(total)), not \(money(facts.cumulativePaid))."))
        }
        let invoice = "Invoice \(facts.invoiceNumber)"
        if let own = table.rows.firstIndex(where: { $0.count > table.reference && $0[table.reference] == invoice }) {
            if amounts[own] != facts.amountDue {
                let shown = amounts[own].map(money) ?? table.rows[own][table.amount]
                found.append(FactProblem(field: "amountDue", check: .invoiceRow,
                                         words: "The payment table shows \(invoice) as \(shown), "
                                             + "not \(money(facts.amountDue))."))
            }
        } else {
            found.append(FactProblem(field: "amountDue", check: .invoiceRow,
                                     words: "\(invoice) is not in the payment table."))
        }
        return found
    }

    /// The page against the bank's own record, which no page can change.
    static func againstTheBank(_ facts: InvoiceFacts, bank: InvoiceBankView) -> [FactProblem] {
        var found: [FactProblem] = []
        if facts.cumulativePaid != bank.paidBefore + facts.amountDue {
            found.append(FactProblem(field: "cumulativePaid", check: .bankRecord, words:
                "The bank paid \(money(bank.paidBefore)) before this invoice; with this invoice's "
                    + "\(money(facts.amountDue)) that is \(money(bank.paidBefore + facts.amountDue)), "
                    + "not \(money(facts.cumulativePaid))."))
        }
        if facts.contractValue != bank.contractValue {
            found.append(FactProblem(field: "contractValue", check: .bankRecord, words:
                "The bank's contract value is \(money(bank.contractValue)), not \(money(facts.contractValue))."))
        }
        let left = bank.contractValue - bank.paidBefore
        if facts.amountDue > left {
            found.append(FactProblem(field: "amountDue", check: .contractRemaining, words:
                "Only \(money(left)) is left on the contract, less than \(money(facts.amountDue))."))
        }
        if !isInside(facts.invoiceDate, from: bank.period.start, to: bank.period.end) {
            found.append(FactProblem(field: "invoiceDate", check: .contractPeriod, words:
                "Outside the contract period, \(bank.period.start) to \(bank.period.end)."))
        }
        return found
    }

    /// A payment history table: its rows below the header, and which columns hold the amount and reference.
    struct PaymentTable {
        let rows: [[String]]
        let amount: Int
        let reference: Int
    }

    /// The first table whose header has an amount and a reference column.
    static func paymentTable(in pages: [PageReading]) -> PaymentTable? {
        for table in pages.flatMap(\.tables) {
            guard let header = table.first?.map({ $0.lowercased() }),
                  let amount = header.firstIndex(where: { $0.contains("amount") }),
                  let reference = header.firstIndex(where: { $0.contains("reference") }) else { continue }
            return PaymentTable(rows: Array(table.dropFirst()), amount: amount, reference: reference)
        }
        return nil
    }

    /// "1,000,000" or "1000000" only; anything else (an OCR "O" for "0") is not a number.
    static func parseAmount(_ cell: String) -> Int? {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^(\d{1,3}(,\d{3})*|\d+)$"#, options: .regularExpression) != nil else { return nil }
        return Int(trimmed.replacingOccurrences(of: ",", with: ""))
    }

    /// ISO dates only; anything that is not a real day is outside.
    static func isInside(_ day: String, from start: String, to end: String) -> Bool {
        let parser = FactGrounding.isoDay
        guard let date = parser.date(from: day), parser.string(from: date) == day,
              let first = parser.date(from: start), let last = parser.date(from: end) else { return false }
        return first <= date && date <= last
    }

    static func money(_ amount: Int) -> String {
        amount.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}
