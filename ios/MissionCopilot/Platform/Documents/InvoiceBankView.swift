import Foundation

/// The bank's view of one invoice (#138, step 6.5.6): what the pack already knows before the mission. A
/// scanned page can never change these numbers; its facts are checked against them.
struct InvoiceBankView: Sendable, Equatable {
    /// The pack field behind each number.
    struct Sources: Sendable, Equatable {
        let paidBefore: [PackCitation]  // every payment counted, in the pack's order
        let contractValue: PackCitation
        let period: PackCitation
        let approver: PackCitation
    }

    let invoice: String
    /// Everything the bank paid before this invoice: every pack payment but the invoice's own row.
    let paidBefore: Int
    /// The invoice's own payment row in the pack, when the bank has paid it already.
    let ownRow: Int?
    let contractValue: Int
    let period: PackContracts.Period
    let approver: String
    let sources: Sources
}

extension PackContracts {
    /// The bank's view of invoice `invoice` ("14" matches the payment "Invoice 14"); nil when the pack has
    /// no such contract.
    func bankView(invoice: String, contract index: Int = 0) -> InvoiceBankView? {
        guard contracts.indices.contains(index) else { return nil }
        let contract = contracts[index], base = "/contracts/\(index)"
        let ownRow = contract.payments.firstIndex { $0.reference == "Invoice \(invoice)" }
        let counted = contract.payments.indices.filter { $0 != ownRow }
        let sources = InvoiceBankView.Sources(
            paidBefore: counted.map { file.cite("\(base)/payments/\($0)/amount") },
            contractValue: file.cite("\(base)/contractValue"), period: file.cite("\(base)/contractPeriod"),
            approver: file.cite("\(base)/paymentApprover"))
        return InvoiceBankView(invoice: invoice, paidBefore: counted.map { contract.payments[$0].amount }.reduce(0, +),
                               ownRow: ownRow, contractValue: contract.contractValue, period: contract.contractPeriod,
                               approver: contract.paymentApprover, sources: sources)
    }
}
