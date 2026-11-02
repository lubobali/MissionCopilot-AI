import Foundation

/// What the bank already knows before the mission, from its own systems (the mission pack). A document
/// can never change these; they are the truth that a planted value is checked against (story #48).
public struct MissionPack: Codable, Equatable, Sendable {
    public let contractStart: String
    public let contractEnd: String
    public let contractValue: Int
    /// Everything the bank paid before the invoice under review.
    public let bankPaidBeforeInvoice: Int
    public let paymentApprover: String

    public init(
        contractStart: String, contractEnd: String, contractValue: Int, bankPaidBeforeInvoice: Int,
        paymentApprover: String
    ) {
        self.contractStart = contractStart
        self.contractEnd = contractEnd
        self.contractValue = contractValue
        self.bankPaidBeforeInvoice = bankPaidBeforeInvoice
        self.paymentApprover = paymentApprover
    }
}

/// Cross-checks by code that catch a value an attacker printed on the page, where grounding alone passes
/// because the fake value is really in the text. Each finding sends its field to a person for review.
public enum FactChecks {
    public enum Check: String, Codable, Sendable {
        case inputLimit, impossibleValue, rowSum, invoiceRow, bankRecord, contractRemaining, contractPeriod
        case duplicateLabel
    }

    public struct Finding: Codable, Equatable, Sendable {
        public let check: Check
        public let field: String
    }

    /// One scanned page is about 1,000 characters; far more is refused before the model sees it (T06).
    public static let maxSourceCharacters = 20_000

    public static func fitsInput(_ source: String) -> Bool { source.count <= maxSourceCharacters }

    public static func run(
        _ facts: ExtractedFacts, source: String, paymentRows: [[String]], pack: MissionPack
    ) -> [Finding] {
        guard fitsInput(source) else { return [Finding(check: .inputLimit, field: "source")] }
        var found = impossibleValues(facts)
        if case .matches = CrossCheck.payments(paymentRows, amountColumn: 2, claimedTotal: facts.cumulativePaid) {
        } else {
            found.append(Finding(check: .rowSum, field: "cumulativePaid"))
        }
        let ownRow = paymentRows.first { $0.count > 2 && $0[1] == "Invoice \(facts.invoiceNumber)" }
        if ownRow.flatMap({ CrossCheck.parseAmount($0[2]) }) != facts.amountDue {
            found.append(Finding(check: .invoiceRow, field: "amountDue"))
        }
        if facts.cumulativePaid != pack.bankPaidBeforeInvoice + facts.amountDue {
            found.append(Finding(check: .bankRecord, field: "cumulativePaid"))
        }
        if facts.contractValue != pack.contractValue {
            found.append(Finding(check: .bankRecord, field: "contractValue"))
        }
        if facts.amountDue > pack.contractValue - pack.bankPaidBeforeInvoice {
            found.append(Finding(check: .contractRemaining, field: "amountDue"))
        }
        if !isInside(facts.invoiceDate, from: pack.contractStart, to: pack.contractEnd) {
            found.append(Finding(check: .contractPeriod, field: "invoiceDate"))
        }
        found += duplicateLabels(in: source).map { Finding(check: .duplicateLabel, field: $0) }
        return found
    }

    /// No amount or distance is below zero, and no more road is built than exists (seen on the phone:
    /// one extra spoken sentence and the model wrote negative numbers).
    static func impossibleValues(_ facts: ExtractedFacts) -> [Finding] {
        let values = [("amountDue", facts.amountDue), ("cumulativePaid", facts.cumulativePaid),
                      ("contractValue", facts.contractValue), ("kmCompleted", facts.kmCompleted),
                      ("kmTotal", facts.kmTotal)]
        var found = values.filter { $0.1 < 0 }.map { Finding(check: .impossibleValue, field: $0.0) }
        if facts.kmTotal >= 0, facts.kmCompleted > facts.kmTotal {
            found.append(Finding(check: .impossibleValue, field: "kmCompleted"))
        }
        return found
    }

    /// The fields a person must review, sorted, each once.
    public static func fieldsToReview(_ findings: [Finding]) -> [String] {
        Array(Set(findings.map(\.field))).sorted()
    }

    /// ISO dates only; anything that is not a real date is outside.
    static func isInside(_ day: String, from start: String, to end: String) -> Bool {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day), parser.string(from: date) == day,
              let first = parser.date(from: start), let last = parser.date(from: end) else { return false }
        return first <= date && date <= last
    }

    /// A label printed with two different values ("Amount due: 480,000" and "Total amount due: 4,800,000")
    /// means the page disagrees with itself: whichever value the model picked, a person decides.
    static let labels: [(field: String, pattern: String)] = [
        ("amountDue", #"(?:amount|total)[^:\n]{0,30}\bdue\b[^:\n]{0,30}:\s*(?:USD\s*)?([\d,]+)"#),
        ("cumulativePaid", #"paid to date[^:\n]{0,40}:\s*(?:USD\s*)?([\d,]+)"#),
        ("contractValue", #"contract value[^:\n]{0,30}:\s*(?:USD\s*)?([\d,]+)"#),
        ("invoiceDate", #"(?m)^\s*date:\s*([^\n]+?)\s*$"#),
        ("kmCompleted", #"road built:\s*(\d+)"#),
    ]

    static func duplicateLabels(in source: String) -> [String] {
        labels.compactMap { field, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            let values = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
                Range($0.range(at: 1), in: source).map {
                    source[$0].replacingOccurrences(of: ",", with: "").lowercased()
                }
            }
            return Set(values).count > 1 ? field : nil
        }
    }
}

/// A payment is approved only by the pack's approver, inside the app. There is deliberately no way to
/// pass document text in here: "APPROVED" printed on a page can never approve anything.
public enum Approval {
    public enum Status: Equatable, Sendable { case pending, approved, rejected }

    public struct Decision: Equatable, Sendable {
        public let by: String
        public let approved: Bool

        public init(by: String, approved: Bool) {
            self.by = by
            self.approved = approved
        }
    }

    /// The approver's latest decision counts; anyone else's is ignored.
    public static func status(decisions: [Decision], pack: MissionPack) -> Status {
        guard let last = decisions.last(where: { $0.by == pack.paymentApprover }) else { return .pending }
        return last.approved ? .approved : .rejected
    }
}
