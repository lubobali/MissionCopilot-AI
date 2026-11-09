import Foundation

/// A stored fact a red flag used (#138): its id, and its name for the words.
struct FactRef: Codable, Sendable, Equatable {
    let id: String
    let name: String
    /// True when the officer typed it and the pages do not show it (#151); nil otherwise.
    var typed: Bool?
}

/// The numbers of one invoice the officer confirmed from scanned pages (#138, step 6.5.10), for the rules
/// that compare payments and progress. Each number keeps the fact it came from.
struct ScannedInvoice: Sendable, Equatable {
    let number: String
    let paid: Int
    let contractValue: Int
    let kmBuilt: Double
    let kmTotal: Double
    let facts: [String: FactRef]

    var subject: String { "Scanned invoice \(number)" }

    /// One invoice per confirmation: confirmFacts writes the 8 facts in field order, invoice number first.
    /// Facts from other rules are left out, and a confirmation missing a number or with one that is not a
    /// whole number makes no invoice.
    static func all(from facts: [Fact]) -> [ScannedInvoice] {
        let scanned = facts.filter { [MissionStore.scanRule, MissionStore.officerRule].contains($0.rule) }
        var groups: [[Fact]] = []
        for fact in scanned {
            if fact.name == InvoiceFacts.fields[0] || groups.isEmpty { groups.append([]) }
            groups[groups.count - 1].append(fact)
        }
        return groups.compactMap(invoice)
    }

    private static func invoice(_ group: [Fact]) -> ScannedInvoice? {
        let byName = Dictionary(group.map { ($0.name, $0) }) { first, _ in first }
        let number = { (name: String) in byName[name].flatMap { Int($0.value) } }
        guard let invoice = byName["invoiceNumber"]?.value, let paid = number("cumulativePaid"),
              let value = number("contractValue"), let built = number("kmCompleted"), let total = number("kmTotal")
        else { return nil }
        return ScannedInvoice(number: invoice, paid: paid, contractValue: value, kmBuilt: Double(built),
                              kmTotal: Double(total),
                              facts: byName.mapValues {
                                  FactRef(id: $0.id, name: $0.name, typed: $0.typedNotOnPage ? true : nil)
                              })
    }

    func cite(_ names: [String]) -> [RedFlagResult.Input] {
        names.compactMap { facts[$0] }.map(RedFlagResult.Input.fact)
    }
}
