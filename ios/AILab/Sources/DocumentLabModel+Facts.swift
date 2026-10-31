#if !NO_MLX
import DocumentLab
import Foundation
import MLXLLM
import MLXLMCommon
import UIKit

/// Spike #15 end to end, offline: Vision reads the pages, the #13 constrained model fills the 8 facts, and
/// code checks each fact against the answer key, grounds it in the scanned text, cross-checks the payment
/// table and computes MC-01. Rule: wrong-but-confident is the failure; missing-and-flagged is acceptable.
extension DocumentLabModel {
    func runScanToFacts() {
        guard #available(iOS 26.0, *) else { return log("Needs iOS 26 or later.") }
        running = true
        Task {
            do {
                try await scanToFacts()
            } catch {
                log("scan -> facts FAILED: \(error)")
            }
            record("thermal state after facts", "\(ProcessInfo.processInfo.thermalState.rawValue) (0 nominal .. 3 critical)")
            save()
            running = false
        }
    }

    @available(iOS 26.0, *)
    private func scanToFacts() async throws {
        let folder = DeviceInfo.documents.appendingPathComponent("LFM2.5-1.2B-Instruct-4bit", isDirectory: true)
        let loadStart = Date()
        let container = try await LLMModelFactory.shared.loadContainer(from: folder, using: LocalTokenizerLoader())
        record("facts: model load ms", "\(Int(Date().timeIntervalSince(loadStart) * 1000))")
        let truth = try Self.answerKey().facts

        var sets: [(label: String, runs: Int, pages: [(DocumentReader.Timed, PageName)])] = []
        sets.append(("clean pages", 3, try await builtInPages()))
        let photos = try await latestPhotoPerPage()
        if photos.count == PageName.allCases.count { sets.append(("photo scans", 1, photos)) }

        for set in sets {
            let source = Self.sourceText(set.pages.map(\.0.page))
            let scanMs = set.pages.reduce(0) { $0 + $1.0.milliseconds }
            for run in 1...set.runs {
                let start = Date()
                let raw = try await StructuredSpike.constrained(container: container, prompt: Self.prompt(source))
                let modelMs = Date().timeIntervalSince(start) * 1000
                check(raw, truth: truth, source: source, pages: set.pages.map(\.0.page),
                      label: "facts \(set.label) #\(run)", timing: "scan \(Int(scanMs)) ms, model \(Int(modelMs)) ms")
            }
        }
    }

    private func check(_ raw: String, truth: ExtractedFacts, source: String, pages: [ReadPage], label: String,
                       timing: String) {
        guard let facts = try? JSONDecoder().decode(ExtractedFacts.self, from: Data(raw.utf8)) else {
            return record(label, "NOT VALID JSON: \(raw.prefix(160)); \(timing)")
        }
        let wrong = Self.wrongFields(facts, truth: truth)
        let grounding = Grounding.check(facts, in: source)
        let mc01 = RiskRules.mc01(facts).map {
            String(format: "%@ (%.0f%% paid vs %.0f%% built)", $0.raised ? "raised" : "not raised",
                   $0.financialPercent, $0.physicalPercent)
        } ?? "cannot compute"
        let wrongButGrounded = wrong.filter { grounding.grounded[$0] != nil }
        record(label, "correct \(8 - wrong.count)/8, grounded \(grounding.grounded.count)/8, "
               + "MC-01 \(mc01), payments \(Self.paymentsCheck(pages, claimed: facts.cumulativePaid)); \(timing)")
        if !wrong.isEmpty { record(label + " wrong", wrong.joined(separator: ", ")) }
        if !grounding.ungrounded.isEmpty {
            record(label + " needs review (ungrounded)", grounding.ungrounded.joined(separator: ", "))
        }
        // The failure the rule forbids: a wrong value that still looks backed by the scan.
        record(label + " wrong but confident", wrongButGrounded.isEmpty ? "none" : wrongButGrounded.joined(separator: ", "))
        if label.hasSuffix("#1") { record(label + " raw", raw) }
    }

    // MARK: - Inputs

    @available(iOS 26.0, *)
    private func builtInPages() async throws -> [(DocumentReader.Timed, PageName)] {
        var pages: [(DocumentReader.Timed, PageName)] = []
        for page in PageName.allCases {
            guard let url = Bundle.main.url(forResource: page.rawValue, withExtension: "png") else {
                throw CocoaError(.fileNoSuchFile)
            }
            pages.append((try await DocumentReader.read(imageData: try Data(contentsOf: url)), page))
        }
        return pages
    }

    /// The newest saved scan of each page (page detected by code).
    @available(iOS 26.0, *)
    private func latestPhotoPerPage() async throws -> [(DocumentReader.Timed, PageName)] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: DeviceInfo.documents.path)) ?? [])
            .filter { $0.hasPrefix("scan-") && $0.hasSuffix(".jpg") }.sorted()
        var newest: [PageName: (DocumentReader.Timed, PageName)] = [:]
        for file in files {
            guard let image = UIImage(contentsOfFile: DeviceInfo.documents.appendingPathComponent(file).path) else {
                continue
            }
            let read = try await readAndDetect(image)
            newest[read.1] = read
        }
        return PageName.allCases.compactMap { newest[$0] }
    }

    // MARK: - Pure helpers

    /// What the model reads: each page's text followed by its tables as rows.
    static func sourceText(_ pages: [ReadPage]) -> String {
        pages.map { $0.transcript + "\n" + TableText.render($0.tables) }.joined(separator: "\n\n")
    }

    static func prompt(_ source: String) -> String {
        """
        Read the two scanned documents and fill in the facts as JSON. Amounts are whole US dollars \
        without commas. Dates are YYYY-MM-DD. bridgeStatus is not_started, in_progress or completed.

        \(source)
        """
    }

    /// Field names whose value differs from the answer key.
    static func wrongFields(_ facts: ExtractedFacts, truth: ExtractedFacts) -> [String] {
        let pairs: [(String, Bool)] = [
            ("invoiceNumber", facts.invoiceNumber == truth.invoiceNumber),
            ("invoiceDate", facts.invoiceDate == truth.invoiceDate),
            ("amountDue", facts.amountDue == truth.amountDue),
            ("cumulativePaid", facts.cumulativePaid == truth.cumulativePaid),
            ("contractValue", facts.contractValue == truth.contractValue),
            ("kmCompleted", facts.kmCompleted == truth.kmCompleted),
            ("kmTotal", facts.kmTotal == truth.kmTotal),
            ("bridgeStatus", facts.bridgeStatus == truth.bridgeStatus),
        ]
        return pairs.filter { !$0.1 }.map(\.0)
    }

    /// The payment history table (header "Date | Reference | Amount") must add up to paid-to-date.
    static func paymentsCheck(_ pages: [ReadPage], claimed: Int) -> String {
        let table = pages.flatMap(\.tables).first { $0.first?.first?.trimmingCharacters(in: .whitespaces) == "Date" }
        guard let table, table.count > 1 else { return "no payment table found" }
        return switch CrossCheck.payments(Array(table.dropFirst()), amountColumn: 2, claimedTotal: claimed) {
        case .matches(let total): "table adds up (\(total))"
        case .mismatch(let tableTotal, let claimed): "MISMATCH table \(tableTotal) vs claimed \(claimed)"
        case .unreadable(let row): "unreadable amount in row \(row + 1)"
        }
    }
}
#endif
