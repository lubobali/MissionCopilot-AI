#if !NO_MLX
import Foundation
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon

/// Spike #13: can the on-device model return valid structured facts every time?
/// The model only fills fields; code checks every value and does all arithmetic (ADR 0005).
enum StructuredSpike {
    static let schema = #"""
    {"type":"object","additionalProperties":false,
     "required":["invoiceNumber","invoiceDate","amountDue","cumulativePaid","contractValue","kmCompleted","kmTotal","bridgeStatus"],
     "properties":{
       "invoiceNumber":{"type":"string"},
       "invoiceDate":{"type":"string","pattern":"^\\d{4}-\\d{2}-\\d{2}$"},
       "amountDue":{"type":"integer"},
       "cumulativePaid":{"type":"integer"},
       "contractValue":{"type":"integer"},
       "kmCompleted":{"type":"integer"},
       "kmTotal":{"type":"integer"},
       "bridgeStatus":{"type":"string","enum":["not_started","in_progress","completed"]}}}
    """#

    static let prompt = """
    Read the two documents and fill in the facts as JSON. Amounts are whole US dollars without commas. \
    Dates are YYYY-MM-DD.

    \(BenchPrompts.t2.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n"))
    """

    struct Facts: Codable, Equatable {
        let invoiceNumber: String
        let invoiceDate: String
        let amountDue: Int
        let cumulativePaid: Int
        let contractValue: Int
        let kmCompleted: Int
        let kmTotal: Int
        let bridgeStatus: String
    }

    /// The true values from the documents (fictional demo data).
    static let truth = Facts(
        invoiceNumber: "14", invoiceDate: "2026-10-12", amountDue: 480_000, cumulativePaid: 8_500_000,
        contractValue: 10_000_000, kmCompleted: 32, kmTotal: 64, bridgeStatus: "not_started"
    )

    struct Check: Codable {
        let mode: String
        let run: Int
        let validJSON: Bool
        let fieldsCorrect: Int
        let financialPct: Double?
        let physicalPct: Double?
        let mc01Raised: Bool?
        let seconds: Double
        let thermalState: String
        let raw: String
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// Code, not the model, computes progress and the MC-01 flag (gap above 20 points).
    static func check(mode: String, run: Int, raw: String, seconds: Double) -> Check {
        let json = extractJSONObject(raw)
        guard let data = json.data(using: .utf8), let facts = try? JSONDecoder().decode(Facts.self, from: data) else {
            return Check(mode: mode, run: run, validJSON: false, fieldsCorrect: 0, financialPct: nil,
                         physicalPct: nil, mc01Raised: nil, seconds: seconds, thermalState: thermal(), raw: raw)
        }
        let pairs: [Bool] = [
            facts.invoiceNumber == truth.invoiceNumber, facts.invoiceDate == truth.invoiceDate,
            facts.amountDue == truth.amountDue, facts.cumulativePaid == truth.cumulativePaid,
            facts.contractValue == truth.contractValue, facts.kmCompleted == truth.kmCompleted,
            facts.kmTotal == truth.kmTotal, facts.bridgeStatus == truth.bridgeStatus
        ]
        let financial = facts.contractValue > 0 ? 100 * Double(facts.cumulativePaid) / Double(facts.contractValue) : nil
        let physical = facts.kmTotal > 0 ? 100 * Double(facts.kmCompleted) / Double(facts.kmTotal) : nil
        let raised = financial.flatMap { f in physical.map { f - $0 > 20 } }
        return Check(mode: mode, run: run, validJSON: true, fieldsCorrect: pairs.filter { $0 }.count,
                     financialPct: financial, physicalPct: physical, mc01Raised: raised, seconds: seconds,
                     thermalState: thermal(), raw: raw)
    }

    /// Free-text answers may wrap JSON in prose or code fences; take the outermost {...}.
    static func extractJSONObject(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return text }
        return String(text[start...end])
    }

    /// Constrained run: the grammar forces valid JSON matching the schema (greedy, deterministic).
    static func constrained(container: ModelContainer, maxTokens: Int = 256) async throws -> String {
        try await container.perform { context in
            let tokenizer = context.tokenizer
            let grammarVocab = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
            let grammarTokenizer = try GrammarTokenizer(
                vocab: grammarVocab.vocab, vocabType: grammarVocab.vocabType,
                eosTokenId: Int32(tokenizer.eosTokenId ?? 0)
            )
            let constraint = try GrammarConstraint(
                tokenizer: grammarTokenizer, jsonSchema: schema, fastForward: true, hostTokenizer: tokenizer
            )
            let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
            // Penalize runs of whitespace-only tokens: without this the greedy loop got stuck
            // emitting tabs between fields until it hit the token limit (spike #13 diagnosis).
            let whitespace = WhitespaceTokenBias.compute(tokenizer: tokenizer)
            var output = ""
            do {
                _ = try GuidedGenerationLoop.run(
                    input: input, context: context, constraint: constraint, maxTokens: maxTokens,
                    vocabSize: grammarTokenizer.vocabSize,
                    whitespaceBias: whitespace.bias, whitespaceTokenIDs: whitespace.tokenIDs
                ) { delta in
                    output += delta
                    return true
                }
            } catch {
                // Keep the partial output so the failure can be diagnosed, not just counted.
                return "INCOMPLETE(\(error)): " + output
            }
            return output
        }
    }

    /// Free run for comparison: same prompt plus the schema as text, no grammar, seeded sampling.
    static func unconstrained(container: ModelContainer, seed: UInt64) async throws -> String {
        let parameters = GenerateParameters(
            maxTokens: 256, temperature: BenchSettings.temperature, topK: Int(BenchSettings.topK),
            repetitionPenalty: BenchSettings.repetitionPenalty, seed: seed
        )
        let session = ChatSession(container, generateParameters: parameters)
        return try await session.respond(to: prompt + "\n\nReply with only JSON matching this schema:\n" + schema)
    }
}
#endif
