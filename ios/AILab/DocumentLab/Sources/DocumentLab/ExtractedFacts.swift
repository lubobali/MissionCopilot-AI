import Foundation

/// The 8 facts of spike #13, as the model returns them (same schema). Code checks every one.
public struct ExtractedFacts: Codable, Equatable, Sendable {
    public var invoiceNumber: String
    public var invoiceDate: String
    public var amountDue: Int
    public var cumulativePaid: Int
    public var contractValue: Int
    public var kmCompleted: Int
    public var kmTotal: Int
    public var bridgeStatus: String
}

/// Cited red-flag rules computed by code, never by the model (ADR 0005, ADR 0010).
public enum RiskRules {
    public struct MC01: Equatable, Sendable {
        public let financialPercent: Double
        public let physicalPercent: Double
        public let raised: Bool
    }

    /// MC-01: payments run ahead of physical progress by more than 20 points.
    public static func mc01(_ facts: ExtractedFacts) -> MC01? {
        guard facts.contractValue > 0, facts.kmTotal > 0 else { return nil }
        let financial = 100 * Double(facts.cumulativePaid) / Double(facts.contractValue)
        let physical = 100 * Double(facts.kmCompleted) / Double(facts.kmTotal)
        return MC01(financialPercent: financial, physicalPercent: physical, raised: financial - physical > 20)
    }
}
