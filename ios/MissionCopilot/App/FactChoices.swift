import Foundation

/// The values printed on the scanned pages for one fact (#151): code finds them, the officer chooses. Found in
/// the Phase 6 proof: with the model's value locked, the officer had to type the right one from memory, and typed
/// the invented one back. The labels the code reads (FactGrounding.labels), the invoice number after "Invoice
/// No.", and the bridge's state words; never the value the check rejected, at most three, in page order.
extension FactReviewModel {
    static let maxChoices = 3

    static func choices(_ field: String, rejected: String?, pages: [PageReading]) -> [Choice] {
        var values = FactGrounding.labelled(in: pages)[field]?.map { FactGrounding.normalized($0, field: field) } ?? []
        let texts = pages.map(FactGrounding.text)
        if field == "invoiceNumber" {
            values += texts.flatMap { matches(#"Invoice No\.? ?([A-Za-z0-9./-]*\d[A-Za-z0-9./-]*)"#, in: $0) }
        }
        if field == "bridgeStatus" {
            values += texts.flatMap { text in
                FactGrounding.bridgeWords.sorted { $0.key < $1.key }.compactMap { key, words in
                    words.contains { FactGrounding.first("bridge[^:|]{0,30}: ?\($0)\\b", in: text) != nil }
                        ? key : nil
                }
            }
        }
        var unique: [String] = []
        for value in values where value != rejected && !unique.contains(value) { unique.append(value) }
        return unique.prefix(maxChoices).map { Choice(value: $0, words: InvoiceFacts.words(field, value: $0)) }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
