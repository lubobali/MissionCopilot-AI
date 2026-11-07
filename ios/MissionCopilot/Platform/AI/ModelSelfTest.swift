import Foundation

/// The app's one model, shared: loaded when first needed, released under pressure (ModelMemoryWatcher, set
/// up when the app starts).
enum AppModel {
    static let host = ModelHost.bundled()
    static let field = FieldModel(engine: host)
}

/// "Test the AI assistant" (#136): spike #13's fixed fictional task (an invoice and a progress report,
/// 8 facts) through the same door every real call uses, checked by code against the true values. Offline,
/// and nothing is stored: it only says whether the assistant works on this iPhone, and how fast.
enum ModelSelfTest {
    typealias Facts = InvoiceFacts

    enum Result: Equatable, Sendable {
        case answered(seconds: Double, right: Int)
        case stopped
        case refused(ModelAnswer<Facts>.Refusal)

        /// All 8 facts right: the assistant works on this iPhone.
        var passed: Bool { self == .answered(seconds: seconds ?? 0, right: ModelSelfTest.factCount) }

        private var seconds: Double? {
            if case .answered(let seconds, _) = self { seconds } else { nil }
        }

        var words: String {
            switch self {
            case .answered(let seconds, let right):
                let time = "Answered in \(seconds.formatted(.number.precision(.fractionLength(1)))) s"
                return right == ModelSelfTest.factCount ? "\(time) · \(right) of 8 facts right"
                    : "\(time) · \(right) of 8 facts right. Check its facts on site."
            case .stopped:
                return "It did not answer within 20 s, so it stopped. "
                    + "Try again; if it keeps stopping, restart the iPhone."
            case .refused(.unavailable(.notInThisBuild)):
                return "It is not in this build of the app. Install the full app."
            case .refused(.unavailable(.failedCheck)):
                return "It failed its safety check, so it stays off. Install the app again."
            case .refused(.unavailable(.couldNotLoad)):
                return "It could not start. Close other apps and try again."
            case .refused:
                return "It answered in a shape the app cannot use. Try again."
            }
        }
    }

    static let factCount = 8

    static let truth = Facts(invoiceNumber: "14", invoiceDate: "2026-10-12", amountDue: 480_000,
                             cumulativePaid: 8_500_000, contractValue: 10_000_000, kmCompleted: 32, kmTotal: 64,
                             bridgeStatus: "not_started")

    static let task = ModelTask<Facts>(prompt: """
        Read the two documents and fill in the facts as JSON. Amounts are whole US dollars without commas. \
        Dates are YYYY-MM-DD.

        INVOICE No. 14 - Kandor Rural Roads Project, Package 1. Date: 12 Oct 2026. Contractor: Sahel Build Ltd. \
        Amount due: USD 480,000. Cumulative paid including this invoice: USD 8,500,000. Contract value: \
        USD 10,000,000.

        CONTRACTOR PROGRESS REPORT, September 2026. Road section 1 to 3, total length 64 km. Completed: 32 km \
        asphalt. Section 3 bridge: not started. Planned completion: 15 Dec 2026.
        """, schema: InvoiceFacts.schema, maxTokens: 256)

    static func run(_ model: FieldModel) async -> Result {
        let start = ContinuousClock.now
        let answer = await model.run(task)
        let took = ContinuousClock.now - start
        let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        switch answer {
        case .answered(let facts): return .answered(seconds: seconds, right: right(facts))
        case .stopped: return .stopped
        case .refused(let why): return .refused(why)
        }
    }

    private static func right(_ facts: Facts) -> Int {
        [facts.invoiceNumber == truth.invoiceNumber, facts.invoiceDate == truth.invoiceDate,
         facts.amountDue == truth.amountDue, facts.cumulativePaid == truth.cumulativePaid,
         facts.contractValue == truth.contractValue, facts.kmCompleted == truth.kmCompleted,
         facts.kmTotal == truth.kmTotal, facts.bridgeStatus == truth.bridgeStatus].filter { $0 }.count
    }
}
