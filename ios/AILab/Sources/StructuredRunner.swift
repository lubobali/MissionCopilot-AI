#if !NO_MLX
import Foundation
import MLXLLM
import MLXLMCommon

/// Runs spike #13: 20 constrained + 20 unconstrained extractions, each checked by code.
enum StructuredRunner {
    static let runs = 20

    static func run(modes: [String] = ["constrained", "free"], runs: Int = 20,
                    log: @MainActor @escaping (String) -> Void) async {
        let folder = DeviceInfo.documents.appendingPathComponent("LFM2.5-1.2B-Instruct-4bit", isDirectory: true)
        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(from: folder, using: LocalTokenizerLoader())
        } catch {
            await log("LOAD FAILED: \(error)")
            return
        }
        var checks: [StructuredSpike.Check] = []
        for mode in modes {
            for index in 1...runs {
                let start = Date()
                let raw: String
                do {
                    raw = mode == "constrained"
                        ? try await StructuredSpike.constrained(container: container)
                        : try await StructuredSpike.unconstrained(container: container, seed: UInt64(index))
                } catch {
                    await log("\(mode) #\(index) FAILED: \(error)")
                    continue
                }
                let check = StructuredSpike.check(mode: mode, run: index, raw: raw, seconds: Date().timeIntervalSince(start))
                checks.append(check)
                if !check.validJSON { await log("   raw: " + String(raw.prefix(240))) }
                let flag = check.mc01Raised.map { $0 ? "MC-01 RAISED" : "MC-01 clear" } ?? "no flag"
                await log(String(format: "%@ #%d: json=%@ fields=%d/8 %@ %.1fs %@", mode, index,
                                 check.validJSON ? "ok" : "BAD", check.fieldsCorrect, flag, check.seconds, check.thermalState))
            }
        }
        for mode in modes {
            let subset = checks.filter { $0.mode == mode }
            let valid = subset.filter(\.validJSON).count
            let perfect = subset.filter { $0.fieldsCorrect == 8 }.count
            await log("\(mode): valid JSON \(valid)/\(subset.count), all 8 fields right \(perfect)/\(subset.count)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = DeviceInfo.documents.appendingPathComponent("bench-structured-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try encoder.encode(checks).write(to: url)
            await log("Saved \(url.lastPathComponent)")
        } catch {
            await log("Save failed: \(error)")
        }
    }
}
#endif
