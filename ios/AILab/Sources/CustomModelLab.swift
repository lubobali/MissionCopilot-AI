import Foundation
import FoundationModels
import Observation
import SwiftUI

// Spike #18: our MLX model (LFM2.5 1.2B, spike #12) behind Apple's LanguageModel protocol (iOS 27), so app
// code could use one API, LanguageModelSession, whatever model runs underneath. The question is whether
// it runs on a phone without Apple Intelligence. Debug lab only: no tools, no guided generation.

@available(iOS 27.0, *)
struct MLXLanguageModel: LanguageModel {
    typealias Executor = MLXExecutor
    let folder: String

    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }
    var executorConfiguration: MLXExecutor.Configuration { .init(folder: folder) }
}

@available(iOS 27.0, *)
struct MLXExecutor: LanguageModelExecutor {
    struct Configuration: Hashable, Sendable { let folder: String }
    typealias Model = MLXLanguageModel

    let configuration: Configuration

    init(configuration: Configuration) throws { self.configuration = configuration }

    nonisolated(nonsending) func respond(to request: LanguageModelExecutorGenerationRequest, model: MLXLanguageModel,
                                         streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let engine = try await SharedMLX.shared.engine(folder: configuration.folder)
        let result = try await engine.generate(Self.lastPrompt(request.transcript))
        await channel.send(.response(action: .appendText(result.text, tokenCount: result.tokens)))
    }

    /// The newest prompt's text: the lab sends one prompt per fresh session.
    static func lastPrompt(_ transcript: Transcript) -> String {
        for entry in transcript.reversed() {
            guard case .prompt(let prompt) = entry else { continue }
            return prompt.segments.compactMap { segment -> String? in
                if case .text(let text) = segment { return text.content }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }
}

/// One loaded model shared by the direct runs and the executor, so both measure generation, not loading.
actor SharedMLX {
    static let shared = SharedMLX()
    private var engines: [String: MLXEngine] = [:]

    func engine(folder: String) async throws -> MLXEngine {
        if let engine = engines[folder] { return engine }
        let engine = MLXEngine()
        try await engine.load(directory: DeviceInfo.documents.appendingPathComponent(folder, isDirectory: true))
        engines[folder] = engine
        return engine
    }
}

@MainActor @Observable
final class CustomModelLabModel {
    static let folder = "LFM2.5-1.2B-Instruct-4bit"
    var log: [String] = ["Runs the spike #12 prompt T1 3 times each way."]
    var running = false
    private var results: [String: String] = [:]

    func run() {
        guard #available(iOS 27.0, *) else { return log.append("Needs iOS 27 or later.") }
        running = true
        Task {
            await self.compare()
            self.save()
            self.running = false
        }
    }

    @available(iOS 27.0, *)
    private func compare() async {
        record("network during run", await DeviceInfo.networkStatus())
        record("Apple's own model on this phone", "\(SystemLanguageModel.default.availability)")
        do {
            let loadStart = Date()
            let engine = try await SharedMLX.shared.engine(folder: Self.folder)
            record("mlx load", String(format: "%.2f s", Date().timeIntervalSince(loadStart)))
            for run in 1...3 {
                var start = Date()
                let direct = try await engine.generate(BenchPrompts.t1)
                let directSeconds = Date().timeIntervalSince(start)
                start = Date()
                let session = LanguageModelSession(model: MLXLanguageModel(folder: Self.folder))
                let answer = try await session.respond(to: BenchPrompts.t1).content
                let sessionSeconds = Date().timeIntervalSince(start)
                record("run \(run)", String(format: "direct %.2f s (%d tokens), via LanguageModelSession %.2f s, "
                                            + "%d characters each way", directSeconds, direct.tokens, sessionSeconds,
                                            answer.count))
                if run == 1 { record("run 1 session answer", String(answer.prefix(400))) }
            }
        } catch {
            record("custom model", "FAILED: \(error)")
        }
    }

    private func record(_ name: String, _ value: String) {
        results[name] = value
        log.append(name + ": " + value)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(results).write(to: DeviceInfo.documents.appendingPathComponent("custom-model-results.json"))
        } catch {
            log.append("save FAILED: \(error)")
        }
    }
}

struct CustomModelView: View {
    @State private var model = CustomModelLabModel()

    var body: some View {
        List {
            Section("Our MLX model behind Apple's LanguageModel API") {
                Button("Run: direct MLX vs LanguageModelSession (3x)") { model.run() }.disabled(model.running)
            }
            Section("Log") {
                ForEach(Array(model.log.enumerated()), id: \.offset) { Text($0.element).font(.footnote.monospaced()) }
            }
        }
        .navigationTitle("Custom model #18")
    }
}
