import Foundation

/// The 8 facts of a scanned invoice and progress report, as the model fills them (spike #13's schema, #138).
/// The model only fills fields; code checks every value and does every sum (ADR 0005).
struct InvoiceFacts: Codable, Equatable, Sendable {
    let invoiceNumber: String
    let invoiceDate: String
    let amountDue: Int
    let cumulativePaid: Int
    let contractValue: Int
    let kmCompleted: Int
    let kmTotal: Int
    let bridgeStatus: String

    static let fields = ["invoiceNumber", "invoiceDate", "amountDue", "cumulativePaid", "contractValue",
                         "kmCompleted", "kmTotal", "bridgeStatus"]

    /// The grammar the model must fit: every field, nothing more, dates as YYYY-MM-DD, three bridge states.
    static let schema = #"""
        {"type":"object","additionalProperties":false,"required":["invoiceNumber","invoiceDate","amountDue",\#
        "cumulativePaid","contractValue","kmCompleted","kmTotal","bridgeStatus"],"properties":{\#
        "invoiceNumber":{"type":"string"},"invoiceDate":{"type":"string","pattern":"^\\d{4}-\\d{2}-\\d{2}$"},\#
        "amountDue":{"type":"integer"},"cumulativePaid":{"type":"integer"},"contractValue":{"type":"integer"},\#
        "kmCompleted":{"type":"integer"},"kmTotal":{"type":"integer"},\#
        "bridgeStatus":{"type":"string","enum":["not_started","in_progress","completed"]}}}
        """#
}

/// Scanned pages to facts (#138, step 6.5.7), through the one model door. Only a schema-valid answer within
/// the time limit comes back as facts, and those are still unchecked; everything else goes to the officer.
enum ScanExtraction {
    enum Outcome: Equatable, Sendable {
        case read(InvoiceFacts)
        case toOfficer(Why)
    }

    /// Why the officer reads the page instead of the model.
    enum Why: Equatable, Sendable {
        case noText
        case tooLong(characters: Int)
        case stopped
        case notUsable
        case unavailable(ModelUnavailable)

        var words: String {
            switch self {
            case .noText: "No text was read on these pages. Scan them again in better light."
            case .tooLong(let characters):
                "These pages hold \(characters.formatted()) characters, too many for the assistant. "
                    + "Scan only the invoice and the progress report."
            case .stopped: "The assistant did not answer within 20 s, so it stopped. Enter the facts yourself."
            case .notUsable: "The assistant answered in a shape the app cannot use. Enter the facts yourself."
            case .unavailable(.notInThisBuild): "The assistant is not in this build. Enter the facts yourself."
            case .unavailable(.failedCheck):
                "The assistant failed its safety check, so it stays off. Enter the facts yourself."
            case .unavailable(.couldNotLoad):
                "The assistant could not start. Close other apps and try again, or enter the facts yourself."
            }
        }
    }

    /// What the model reads: each page's text, then its tables one row per line, pages a blank line apart.
    static func source(_ pages: [PageReading]) -> String {
        pages.map { page in
            ([page.transcript] + page.tables.map { $0.map { $0.joined(separator: " | ") }.joined(separator: "\n") })
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func task(_ source: String) -> ModelTask<InvoiceFacts> {
        ModelTask(prompt: """
            Read the scanned invoice and progress report and fill in the facts as JSON. Amounts are whole US \
            dollars without commas. Dates are YYYY-MM-DD. bridgeStatus is not_started, in_progress or completed.

            \(source)
            """, schema: InvoiceFacts.schema, maxTokens: 256)
    }

    static func extract(_ pages: [PageReading], model: FieldModel) async -> Outcome {
        let source = source(pages)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .toOfficer(.noText) }
        switch await model.run(task(source)) {
        case .answered(let facts): return .read(facts)
        case .stopped: return .toOfficer(.stopped)
        case .refused(.inputTooLong(let characters)): return .toOfficer(.tooLong(characters: characters))
        case .refused(.unavailable(let why)): return .toOfficer(.unavailable(why))
        case .refused(.notSchemaValid), .refused(.failed): return .toOfficer(.notUsable)
        }
    }
}
