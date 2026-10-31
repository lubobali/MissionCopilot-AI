import Foundation

/// Vision tables as plain rows the model can read: one line per row, cells separated by " | ".
public enum TableText {
    public static func render(_ tables: [[[String]]]) -> String {
        tables.map { table in table.map { $0.joined(separator: " | ") }.joined(separator: "\n") }
            .joined(separator: "\n\n")
    }
}

/// Checks one part of a document against another, by code.
public enum CrossCheck {
    public enum Payments: Equatable, Sendable {
        case matches(total: Int)
        case mismatch(tableTotal: Int, claimed: Int)
        /// An amount that does not parse as a number: reported, never guessed.
        case unreadable(row: Int)
    }

    /// The payment history table must add up to the "paid to date" the invoice claims.
    public static func payments(_ rows: [[String]], amountColumn: Int, claimedTotal: Int) -> Payments {
        var total = 0
        for (index, row) in rows.enumerated() {
            guard amountColumn < row.count, let amount = parseAmount(row[amountColumn]) else {
                return .unreadable(row: index)
            }
            total += amount
        }
        return total == claimedTotal ? .matches(total: total) : .mismatch(tableTotal: total, claimed: claimedTotal)
    }

    /// "1,000,000" or "1000000" only; anything else (an OCR "O" for "0") is not a number.
    static func parseAmount(_ cell: String) -> Int? {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^(\d{1,3}(,\d{3})*|\d+)$"#, options: .regularExpression) != nil else { return nil }
        return Int(trimmed.replacingOccurrences(of: ",", with: ""))
    }
}
