import Foundation

/// A fact's value in the officer's words, and a typed correction checked against its field (#138, 6.5.11).
extension InvoiceFacts {
    static let blank = InvoiceFacts(invoiceNumber: "", invoiceDate: "", amountDue: 0, cumulativePaid: 0,
                                    contractValue: 0, kmCompleted: 0, kmTotal: 0, bridgeStatus: "")

    static let bridgeStates = ["not_started": "Not started", "in_progress": "In progress", "completed": "Completed"]
    private static let amounts: Set = ["amountDue", "cumulativePaid", "contractValue"]
    private static let distances: Set = ["kmCompleted", "kmTotal"]

    /// "USD 480,000", "32 km", "12 October 2026", "Not started"; anything else as it is.
    static func words(_ field: String, value: String) -> String {
        if amounts.contains(field), let amount = Int(value) { return "USD " + InvoiceChecks.money(amount) }
        if distances.contains(field), let distance = Int(value) { return "\(distance) km" }
        if field == "invoiceDate", let day = FactGrounding.isoDay.date(from: value) {
            return FactGrounding.formatter("d MMMM yyyy").string(from: day)
        }
        if field == "bridgeStatus" { return bridgeStates[value] ?? value }
        return value
    }

    /// A correction in the stored form, or nil when it does not fit the field (then `hint` says how).
    static func corrected(_ field: String, typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if amounts.contains(field) || distances.contains(field) {
            let digits = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
            return Int(digits).map(String.init)
        }
        if field == "invoiceDate" {
            let parser = FactGrounding.isoDay
            return parser.date(from: text).map(parser.string) == text ? text : nil
        }
        if field == "invoiceNumber" {  // found on the iPhone: "abc" was taken; a number has a digit, like INV-14/A
            let pattern = #"^[A-Za-z0-9 ./-]*\d[A-Za-z0-9 ./-]*$"#
            return text.range(of: pattern, options: .regularExpression) == nil ? nil : text
        }
        if field == "bridgeStatus" {
            let key = text.lowercased().replacingOccurrences(of: " ", with: "_")
            return bridgeStates[key] == nil ? nil : key
        }
        return text
    }

    static func hint(_ field: String) -> String {
        let examples = ["amountDue": "480000", "cumulativePaid": "8500000", "contractValue": "10000000",
                        "kmCompleted": "32", "kmTotal": "64"]
        if let example = examples[field] { return "Enter a whole number, like \(example)." }
        switch field {
        case "invoiceDate": return "Enter the date as year-month-day, like 2026-10-12."
        case "bridgeStatus": return "Enter not started, in progress or completed."
        case "invoiceNumber": return "Enter the invoice number as printed, like 14."
        default: return "Enter it as printed on the page."
        }
    }
}
