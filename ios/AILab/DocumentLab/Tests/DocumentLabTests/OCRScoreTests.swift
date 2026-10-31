import Testing
@testable import DocumentLab

struct OCRScoreTests {
    private let expected = ExpectedPage(
        lines: ["Invoice No. 14", "Date: 12 October 2026"],
        headers: ["Date", "Amount"],
        rows: [["15 Feb 2025", "1,000,000"], ["30 Sep 2025", ""]])

    @Test func perfectReadScoresFull() {
        let read = ReadPage(transcript: "Invoice No. 14\nDate: 12 October 2026",
                            tables: [[["Date", "Amount"], ["15 Feb 2025", "1,000,000"], ["30 Sep 2025", ""]]])

        let score = OCRScore.score(read, against: expected)

        #expect(score.linesFound == 2 && score.linesTotal == 2)
        #expect(score.cellsMatched == 6 && score.cellsTotal == 6)
        #expect(score.missing.isEmpty)
    }

    @Test func spacingAndLineBreaksDoNotCountAsErrors() {
        let read = ReadPage(transcript: "Invoice  No. 14 Date:\n12 October   2026", tables: [])

        #expect(OCRScore.score(read, against: expected).linesFound == 2)
    }

    @Test func wrongDigitIsAMissAndIsListed() {
        let read = ReadPage(transcript: "Invoice No. 14\nDate: 12 October 2028",
                            tables: [[["Date", "Amount"], ["15 Feb 2025", "1,000,800"], ["30 Sep 2025", ""]]])

        let score = OCRScore.score(read, against: expected)

        #expect(score.linesFound == 1)
        #expect(score.cellsMatched == 5)
        #expect(score.missing.contains("line: Date: 12 October 2026"))
        #expect(score.missing.contains("cell r1c1: 1,000,000 (read: 1,000,800)"))
    }

    @Test func missingTableScoresZeroCells() {
        let read = ReadPage(transcript: "Invoice No. 14\nDate: 12 October 2026", tables: [])

        let score = OCRScore.score(read, against: expected)

        #expect(score.cellsMatched == 0)
        #expect(score.missing.contains("table: not found"))
    }
}
