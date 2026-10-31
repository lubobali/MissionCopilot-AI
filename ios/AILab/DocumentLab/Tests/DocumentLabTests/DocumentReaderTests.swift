import Foundation
import Testing
@testable import DocumentLab

/// Reads the committed scan documents (docs/demo/scans) on the Simulator and scores them against the
/// answer key. The Simulator reads the Mac's file system, so the files are not copied into the package.
struct DocumentReaderTests {
    struct AnswerKey: Decodable {
        struct Page: Decodable { let lines: [String] }
        struct Table: Decodable { let headers: [String]; let rows: [[String]] }
        let pages: [String: Page]
        let tables: [String: Table]
    }

    static let scans = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/demo/scans")

    private func expected(_ name: String) throws -> ExpectedPage {
        let key = try JSONDecoder().decode(AnswerKey.self,
                                           from: Data(contentsOf: Self.scans.appendingPathComponent("answer-key.json")))
        let page = try #require(key.pages[name])
        let table = try #require(key.tables[name])
        return ExpectedPage(lines: page.lines, headers: table.headers, rows: table.rows)
    }

    @Test(arguments: ["invoice-14", "progress-report-2026-09"])
    func cleanPageIsReadAndScored(name: String) async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let image = try Data(contentsOf: Self.scans.appendingPathComponent("\(name).png"))

        let result = try await DocumentReader.read(imageData: image)
        let score = OCRScore.score(result.page, against: try expected(name))

        print("SCORE \(name): lines \(score.linesFound)/\(score.linesTotal), cells \(score.cellsMatched)/\(score.cellsTotal), "
              + "tables \(result.page.tables.count), \(Int(result.milliseconds)) ms")
        for miss in score.missing { print("MISS \(name): \(miss)") }
        // Clean, computer-made pages must read perfectly; photos are scored on the phone, not here.
        #expect(score.linesFound == score.linesTotal)
        #expect(score.cellsMatched == score.cellsTotal)
    }
}
