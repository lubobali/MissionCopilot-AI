import DocumentLab
import Foundation
import Observation
import UIKit

/// Spike #15 proofs on the iPhone: Vision reads the built-in pages (does the A15 run it, how fast) and
/// camera scans in real conditions, each scored by code against the answer key. Debug lab only.
@MainActor @Observable
final class DocumentLabModel {
    enum PageName: String, CaseIterable, Identifiable {
        case invoice = "invoice-14"
        case report = "progress-report-2026-09"
        var id: String { rawValue }
    }

    enum Condition: String, CaseIterable, Identifiable {
        case printedFlat = "printed, flat, good light"
        case angled = "printed, at an angle"
        case lowLight = "printed, low light"
        case screen = "photo of a screen"
        var id: String { rawValue }
    }

    private(set) var log: [String] = ["Start with: Read built-in pages."]
    private(set) var running = false
    private var results: [String: String] = [:]

    func readBuiltInPages() {
        guard #available(iOS 26.0, *) else { return log("Needs iOS 26 or later.") }
        running = true
        Task {
            // Twice each: the first run includes loading Vision's models (cold), the second is warm.
            for round in ["cold", "warm"] {
                for page in PageName.allCases {
                    do {
                        guard let url = Bundle.main.url(forResource: page.rawValue, withExtension: "png") else {
                            log("\(page.rawValue).png missing from the app")
                            continue
                        }
                        let result = try await DocumentReader.read(imageData: try Data(contentsOf: url))
                        try score(result, page: page, label: "built-in \(page.rawValue) \(round)")
                    } catch {
                        log("built-in \(page.rawValue) FAILED: \(error)")
                    }
                }
            }
            record("thermal state", "\(ProcessInfo.processInfo.thermalState.rawValue) (0 nominal .. 3 critical)")
            save()
            running = false
        }
    }

    func scanned(_ images: [UIImage], page: PageName, condition: Condition) {
        guard #available(iOS 26.0, *) else { return log("Needs iOS 26 or later.") }
        guard let image = images.first, let cgImage = image.cgImage else { return log("No page scanned.") }
        running = true
        let stamp = Int(Date().timeIntervalSince1970)
        if let jpeg = image.jpegData(compressionQuality: 0.8) {
            try? jpeg.write(to: DeviceInfo.documents.appendingPathComponent("scan-\(page.rawValue)-\(stamp).jpg"))
        }
        Task {
            do {
                let result = try await DocumentReader.read(cgImage: cgImage, orientation: Self.orientation(image))
                try score(result, page: page, label: "scan \(page.rawValue), \(condition.rawValue), \(stamp)")
            } catch {
                log("scan FAILED: \(error)")
            }
            save()
            running = false
        }
    }

    @available(iOS 26.0, *)
    private func score(_ result: DocumentReader.Timed, page: PageName, label: String) throws {
        let expected = try Self.expected(page)
        let score = OCRScore.score(result.page, against: expected)
        record(label, "lines \(score.linesFound)/\(score.linesTotal), cells \(score.cellsMatched)/\(score.cellsTotal), "
               + "\(Int(result.milliseconds)) ms")
        if !score.missing.isEmpty {
            record(label + " misses", score.missing.prefix(8).joined(separator: " | "))
        }
    }

    private struct AnswerKey: Decodable {
        struct Page: Decodable { let lines: [String] }
        struct Table: Decodable { let headers: [String]; let rows: [[String]] }
        let pages: [String: Page]
        let tables: [String: Table]
    }

    private static func expected(_ page: PageName) throws -> ExpectedPage {
        guard let url = Bundle.main.url(forResource: "answer-key", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let key = try JSONDecoder().decode(AnswerKey.self, from: Data(contentsOf: url))
        guard let lines = key.pages[page.rawValue]?.lines, let table = key.tables[page.rawValue] else {
            throw CocoaError(.coderValueNotFound)
        }
        return ExpectedPage(lines: lines, headers: table.headers, rows: table.rows)
    }

    private static func orientation(_ image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        default: .up
        }
    }

    private func record(_ name: String, _ value: String) {
        results[name] = value
        log(name + ": " + value)
    }

    private func log(_ line: String) { log.append(line) }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = DeviceInfo.documents.appendingPathComponent("document-results.json")
        do { try encoder.encode(results).write(to: url) } catch { log("save FAILED: \(error)") }
    }
}
