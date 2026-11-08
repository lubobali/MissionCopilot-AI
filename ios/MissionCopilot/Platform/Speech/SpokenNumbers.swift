import Foundation

/// A number, amount, percent or date heard in a debrief (#142, step 6.6.7): "heard" until the officer confirms
/// it, because the speech engine writes wrong numbers with no warning (spike #14, and "480,000 hours" on the
/// iPhone). It keeps the words as heard, its unit, the words around it and where it is in the transcript.
struct HeardNumber: Sendable, Equatable {
    enum Kind: String, Sendable { case amount, percent, distance, time, date, count }

    /// The number without commas ("480000"), or the date as said ("March 15").
    let value: String
    let words: String
    let unit: String?
    var kind: Kind
    let context: String
    let found: TextSpan
    /// The invoice this amount follows ("14" after "invoice 14"), when it does.
    var invoice: String?
    /// Said right after "paid".
    var paid = false
    var problems: [String] = []
    /// The pack's value when the pack disagrees with what was heard, offered to the officer in one tap.
    var expected: String?
}

/// Finds and checks the numbers in a transcript. Pure code, no model.
enum SpokenNumbers {
    static func find(_ transcript: String) -> [HeardNumber] {
        NumberReader(transcript).read()
    }

    /// Known pack values: an amount after "invoice N" against the pack's invoice N, a "paid" amount against the
    /// bank's payments, and km against the road's length. Without a pack nothing is checked against it.
    static func check(_ heard: [HeardNumber], contracts: PackContracts?) -> [HeardNumber] {
        guard let contract = contracts?.contracts.first else { return heard }
        let money = { (amount: Int) in InvoiceChecks.money(amount) }
        return heard.map { number in
            var checked = number
            guard let value = Double(number.value) else { return checked }
            if let invoice = number.invoice, number.kind == .amount {
                if let payment = contract.payments.first(where: { $0.reference == "Invoice \(invoice)" }) {
                    if Double(payment.amount) != value {
                        checked.expected = String(payment.amount)
                        checked.problems.append("The pack's invoice \(invoice) is \(money(payment.amount)), "
                                                + "not \(money(Int(value))).")
                    }
                } else {
                    // Found on the iPhone: "invoice 14" was heard as "invoice 36"; the pack's own invoices help.
                    let known = contract.payments.compactMap { payment in
                        payment.reference.hasPrefix("Invoice ") ? String(payment.reference.dropFirst(8)) : nil
                    }
                    let list = known.count > 1 ? known.dropLast().joined(separator: ", ") + " and " + (known.last ?? "")
                        : known.joined()
                    checked.problems.append("Invoice \(invoice) is not in the pack."
                                            + (known.isEmpty ? "" : " The pack has invoices \(list)."))
                }
            }
            let paid = contract.payments.map(\.amount).reduce(0, +)
            if number.paid, number.kind == .amount, Double(paid) != value {
                checked.expected = String(paid)
                checked.problems.append("The bank's payments add up to \(money(paid)), not \(money(Int(value))).")
            }
            let road = contract.physicalProgress.kmTotal
            if number.kind == .distance, value > road {
                checked.problems.append("The road is \(Int(road)) km long; \(number.value) km is more than all of it.")
            }
            return checked
        }
    }
}
