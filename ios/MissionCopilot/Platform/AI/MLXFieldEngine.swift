import Foundation
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon

/// The real model on the iPhone (#136, step 6.4.4): the bundled LFM2.5 through MLX, the way spike #13 proved
/// it. The answer is forced by a grammar built from the task's JSON schema, greedy and deterministic; runs of
/// whitespace tokens are pushed down (without it the loop emitted tabs until the token cap, spike #13). The
/// loop stops at the next token once the time limit cancels the call. MLX needs the GPU: the Simulator tests
/// use a fake engine, and this one is proven on the phone.
struct MLXFieldEngine: ModelEngine {
    /// The GPU cache MLX keeps between runs: capped so it cannot grow past what the phone can spare.
    static let cacheLimit = 512 * 1024 * 1024

    let container: ModelContainer

    static func load(from folder: URL) async throws -> any ModelEngine {
        Memory.cacheLimit = cacheLimit
        let container = try await LLMModelFactory.shared.loadContainer(from: folder, using: LocalTokenizerLoader())
        return MLXFieldEngine(container: container)
    }

    static func clearMemory() async {
        Memory.clearCache()
    }

    func generate(_ request: ModelRequest) async throws -> String {
        try await container.perform { context in
            let tokenizer = context.tokenizer
            let vocabulary = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
            let grammarTokenizer = try GrammarTokenizer(
                vocab: vocabulary.vocab, vocabType: vocabulary.vocabType, eosTokenId: Int32(tokenizer.eosTokenId ?? 0))
            let constraint = try GrammarConstraint(tokenizer: grammarTokenizer, jsonSchema: request.schema,
                                                   fastForward: true, hostTokenizer: tokenizer)
            let input = try await context.processor.prepare(input: UserInput(prompt: request.prompt))
            let whitespace = WhitespaceTokenBias.compute(tokenizer: tokenizer)
            var output = ""
            _ = try GuidedGenerationLoop.run(
                input: input, context: context, constraint: constraint, maxTokens: request.maxTokens,
                vocabSize: grammarTokenizer.vocabSize,
                whitespaceBias: whitespace.bias, whitespaceTokenIDs: whitespace.tokenIDs
            ) { delta in
                output += delta
                return !Task.isCancelled  // past the time limit: stop at the next token
            }
            try Task.checkCancellation()
            return output
        }
    }
}

extension ModelHost {
    /// The app's model: the bundled one, checked against the pinned key before every load.
    static func bundled(resources: URL? = Bundle.main.resourceURL) -> ModelHost {
        ModelHost(check: { await BundledModel.check(resources: resources) },
                  load: { folder in try await MLXFieldEngine.load(from: folder) },
                  clearMemory: { await MLXFieldEngine.clearMemory() },
                  folder: BundledModel.modelFolder(in: resources ?? URL(filePath: "/")))
    }
}
