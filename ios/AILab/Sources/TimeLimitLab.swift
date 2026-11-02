#if !NO_MLX
import DocumentLab
import Foundation
import MLXLLM
import MLXLMCommon
import Observation
import Synchronization
import SwiftUI

/// Story #62 on the iPhone: the model time limit on a real invoice page, offline. Three runs with the
/// app's 20 s limit (each should answer) and three with 1 s (each should stop), timing both when the app
/// got control back and when the model really stopped working.
@MainActor @Observable
final class TimeLimitLabModel {
    var log: [String] = ["Reads the built-in invoice, then runs the model 3x with 20 s and 3x with 1 s."]
    var running = false
    private var results: [String: String] = [:]

    func run() {
        guard #available(iOS 26.0, *) else { return log.append("Needs iOS 26 or later.") }
        running = true
        Task {
            results["network during run"] = await DeviceInfo.networkStatus()
            do {
                try await self.measure()
            } catch {
                self.record("run FAILED", "\(error)")
            }
            self.save()
            self.running = false
        }
    }

    @available(iOS 26.0, *)
    private func measure() async throws {
        guard let url = Bundle.main.url(forResource: "invoice-14", withExtension: "png") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let page = try await DocumentReader.read(imageData: Data(contentsOf: url)).page
        let prompt = InjectionLabModel.prompt(page.transcript + "\n" + TableText.render(page.tables))
        let folder = DeviceInfo.documents.appendingPathComponent("LFM2.5-1.2B-Instruct-4bit", isDirectory: true)
        let container = try await LLMModelFactory.shared.loadContainer(from: folder, using: LocalTokenizerLoader())
        for (label, limit) in [("20 s", TimeLimit.model), ("1 s", TimeLimit(.seconds(1)))] {
            for run in 1...3 {
                try await timed(label: "limit \(label) #\(run)", limit: limit, container: container, prompt: prompt)
            }
        }
    }

    /// The outcome, when the app got control back, and when the model's work really ended.
    private func timed(label: String, limit: TimeLimit, container: ModelContainer, prompt: String) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let workEnded = Mutex<ContinuousClock.Instant?>(nil)
        let outcome = try await limit.run {
            defer { workEnded.withLock { $0 = ContinuousClock.now } }
            return try await StructuredSpike.unlimited(container: container, prompt: prompt, maxTokens: 256)
        }
        let back = clock.now - start
        while workEnded.withLock({ $0 }) == nil, clock.now - start < .seconds(60) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let ended = workEnded.withLock { $0 }.map { "\(ms($0 - start)) ms" } ?? "not within 60 s"
        let answer = outcome.usable.map { $0.hasPrefix("{") ? "answered" : "incomplete" } ?? "STOPPED, not used"
        record(label, "\(answer); control back \(ms(back)) ms; model work ended \(ended); "
               + "free memory \(DeviceInfo.freeMemoryMB()) MB")
    }

    private func ms(_ duration: Duration) -> Int {
        Int(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }

    private func record(_ name: String, _ value: String) {
        results[name] = value
        log.append(name + ": " + value)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(results).write(to: DeviceInfo.documents.appendingPathComponent("time-limit-results.json"))
    }
}

struct TimeLimitView: View {
    @State private var model = TimeLimitLabModel()

    var body: some View {
        List {
            Section("Model time limit (#62), offline") {
                Button("Run 3x 20 s and 3x 1 s") { model.run() }.disabled(model.running)
                if model.running { ProgressView() }
            }
            Section("Log") {
                ForEach(Array(model.log.enumerated()), id: \.offset) { Text($0.element).font(.footnote.monospaced()) }
            }
        }
        .navigationTitle("Time limit #62")
    }
}
#endif
