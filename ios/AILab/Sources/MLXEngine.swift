import Foundation
import MLXLLM
import MLXLMCommon

/// MLX Swift LM 3.32.3, model loaded from a local folder (fully offline).
actor MLXEngine {
    private var container: ModelContainer?

    func load(directory: URL) async throws {
        container = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader()
        )
    }

    func generate(_ prompt: String) async throws -> (text: String, ttft: Double, tps: Double, tokens: Int) {
        guard let container else { throw LlamaError.loadFailed }
        let parameters = GenerateParameters(
            maxTokens: BenchSettings.maxTokens,
            temperature: BenchSettings.temperature,
            topK: Int(BenchSettings.topK),
            repetitionPenalty: BenchSettings.repetitionPenalty
        )
        // A fresh session per test, so no conversation carries over between tests.
        let session = ChatSession(container, generateParameters: parameters)
        let start = Date()
        var firstChunkAt: Date?
        var text = ""
        var info: GenerateCompletionInfo?
        for try await item in session.streamDetails(to: prompt) {
            switch item {
            case .chunk(let chunk):
                if firstChunkAt == nil { firstChunkAt = Date() }
                text += chunk
            case .info(let completion):
                info = completion
            default:
                break
            }
        }
        let tokens = info?.generationTokenCount ?? 0
        let generateTime = info?.generateTime ?? 0
        let tps = generateTime > 0 ? Double(tokens) / generateTime : 0
        return (text, (firstChunkAt ?? Date()).timeIntervalSince(start), tps, tokens)
    }
}
