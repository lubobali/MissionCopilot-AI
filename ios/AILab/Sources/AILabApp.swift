import SwiftUI

@main
struct AILabApp: App {
    var body: some Scene {
        WindowGroup { BenchView() }
    }
}

struct BenchView: View {
    @State private var log: [String] = ["Models go in this app's Documents folder."]
    @State private var running = false

    private let ggufName = "LFM2.5-1.2B-Instruct-Q4_0.gguf"
    private let mlxFolder = "LFM2.5-1.2B-Instruct-4bit"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Run llama.cpp (4 tests x \(BenchSettings.repeats))") { start(.llama) }
                    #if !NO_MLX
                    Button("Run MLX (4 tests x \(BenchSettings.repeats))") { start(.mlx) }
                    Button("Diagnose constrained (x3)") {
                        running = true
                        Task {
                            await StructuredRunner.run(modes: ["constrained"], runs: 3) { line in log.append(line) }
                            running = false
                        }
                    }
                    Button("Run structured output (#13: 20 + 20)") {
                        running = true
                        Task {
                            await StructuredRunner.run { line in log.append(line) }
                            running = false
                        }
                    }
                    #endif
                }
                .disabled(running)
                Section("Encryption") {
                    NavigationLink("Encryption proofs (#16)") { EncryptionView() }
                    NavigationLink("Evidence proofs (#17)") { EvidenceView() }
                    NavigationLink("Documents (#15)") { DocumentView() }
                }
                Section("Free memory: \(DeviceInfo.freeMemoryMB()) MB") {
                    ForEach(Array(log.enumerated()), id: \.offset) { Text($0.element).font(.footnote.monospaced()) }
                }
            }
            .navigationTitle("MC AI Lab")
        }
    }

    private enum Engine: String { case llama, mlx }

    private func start(_ engine: Engine) {
        running = true
        Task {
            await run(engine)
            running = false
        }
    }

    private func append(_ line: String) { log.append(line) }

    private func run(_ engine: Engine) async {
        let docs = DeviceInfo.documents
        let before = DeviceInfo.freeMemoryMB()
        let loadStart = Date()
        let llama = LlamaEngine()
        #if !NO_MLX
        let mlx = MLXEngine()
        #endif
        do {
            switch engine {
            case .llama: try await llama.load(path: docs.appendingPathComponent(ggufName).path)
            case .mlx:
                #if NO_MLX
                return
                #else
                try await mlx.load(directory: docs.appendingPathComponent(mlxFolder, isDirectory: true))
                #endif
            }
        } catch {
            append("\(engine.rawValue) LOAD FAILED: \(error)")
            return
        }
        var report = BenchReport(
            engine: engine.rawValue,
            model: engine == .llama ? ggufName : mlxFolder,
            device: "iPhone 13 Pro Max",
            date: Date(),
            loadSeconds: Date().timeIntervalSince(loadStart),
            freeMemoryBeforeLoadMB: before,
            freeMemoryAfterLoadMB: DeviceInfo.freeMemoryMB(),
            runs: []
        )
        append(String(format: "%@ loaded in %.1fs, free %d -> %d MB", engine.rawValue, report.loadSeconds,
                      before, report.freeMemoryAfterLoadMB))
        for repeatIndex in 1...BenchSettings.repeats {
            for test in BenchPrompts.all {
                do {
                    let result = switch engine {
                    case .llama: try await llama.generate(test.text)
                    case .mlx:
                        #if NO_MLX
                        throw LlamaError.loadFailed
                        #else
                        try await mlx.generate(test.text)
                        #endif
                    }
                    let run = BenchRun(
                        engine: engine.rawValue, test: test.id, run: repeatIndex,
                        timeToFirstTokenMs: result.ttft * 1000, tokensPerSecond: result.tps,
                        generatedTokens: result.tokens, freeMemoryAfterMB: DeviceInfo.freeMemoryMB(), output: result.text
                    )
                    report.runs.append(run)
                    append(String(format: "%@ #%d: %.1f tok/s, first %.0f ms, %d tokens", test.id, repeatIndex,
                                  run.tokensPerSecond, run.timeToFirstTokenMs, run.generatedTokens))
                } catch {
                    append("\(test.id) #\(repeatIndex) FAILED: \(error)")
                }
            }
        }
        do {
            let url = try DeviceInfo.save(report)
            append("Saved \(url.lastPathComponent)")
        } catch {
            append("Save failed: \(error)")
        }
    }
}
