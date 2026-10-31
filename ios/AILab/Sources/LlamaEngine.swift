import Foundation
import llama

enum LlamaError: Error { case loadFailed, contextFailed, templateFailed, tokenizeFailed, decodeFailed }

/// llama.cpp b11960 (= v0.8.0) through its C API. Raw pointers never leave this actor.
actor LlamaEngine {
    private var model: OpaquePointer?
    private var context: OpaquePointer?

    func load(path: String) throws {
        llama_backend_init()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99 // everything on Metal
        guard let loaded = llama_model_load_from_file(path, modelParams) else { throw LlamaError.loadFailed }
        model = loaded
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 4096
        contextParams.n_batch = 512
        guard let ctx = llama_init_from_model(loaded, contextParams) else { throw LlamaError.contextFailed }
        context = ctx
    }

    /// Returns the text, time to first token (s), decode speed (tokens/s) and token count.
    func generate(_ prompt: String) throws -> (text: String, ttft: Double, tps: Double, tokens: Int) {
        guard let model, let context else { throw LlamaError.loadFailed }
        let vocab = llama_model_get_vocab(model)
        llama_memory_clear(llama_get_memory(context), true)

        let formatted = try chatFormatted(prompt)
        var tokens = try tokenize(formatted, vocab: vocab)

        let sampler = makeSampler(vocab: vocab)
        defer { llama_sampler_free(sampler) }

        let start = Date()
        var firstTokenAt: Date?
        var outputBytes: [UInt8] = [] // decoded once at the end: accents can span two tokens
        var generated = 0
        // The token pointer is only valid inside the closure, so decode inside it.
        let promptStatus = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard promptStatus == 0 else { throw LlamaError.decodeFailed }

        while generated < BenchSettings.maxTokens {
            var next = llama_sampler_sample(sampler, context, -1)
            if firstTokenAt == nil { firstTokenAt = Date() }
            if llama_vocab_is_eog(vocab, next) { break }
            outputBytes += pieceBytes(next, vocab: vocab)
            generated += 1
            let status = withUnsafeMutablePointer(to: &next) { pointer in
                llama_decode(context, llama_batch_get_one(pointer, 1))
            }
            guard status == 0 else { throw LlamaError.decodeFailed }
        }

        let first = firstTokenAt ?? Date()
        let decodeSeconds = Date().timeIntervalSince(first)
        let tps = decodeSeconds > 0 ? Double(max(generated - 1, 0)) / decodeSeconds : 0
        return (String(decoding: outputBytes, as: UTF8.self), first.timeIntervalSince(start), tps, generated)
    }

    private func makeSampler(vocab: OpaquePointer?) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        llama_sampler_chain_add(
            chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, BenchSettings.repetitionPenalty, 0, 0)
        )
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(BenchSettings.topK))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(BenchSettings.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(42))
        return chain
    }

    /// Uses the chat template stored in the GGUF file.
    private func chatFormatted(_ prompt: String) throws -> String {
        guard let model, let template = llama_model_chat_template(model, nil) else { throw LlamaError.templateFailed }
        return try "user".withCString { role in
            try prompt.withCString { content in
                var message = llama_chat_message(role: role, content: content)
                var buffer = [CChar](repeating: 0, count: prompt.utf8.count * 2 + 512)
                let written = llama_chat_apply_template(template, &message, 1, true, &buffer, Int32(buffer.count))
                guard written > 0, Int(written) < buffer.count else { throw LlamaError.templateFailed }
                return String(decoding: buffer[0..<Int(written)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
    }

    private func tokenize(_ text: String, vocab: OpaquePointer?) throws -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 16)
        let count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        guard count > 0 else { throw LlamaError.tokenizeFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private func pieceBytes(_ token: llama_token, vocab: OpaquePointer?) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        let length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        guard length > 0 else { return [] }
        return buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }
    }
}
