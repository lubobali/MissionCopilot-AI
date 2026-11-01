import Foundation

/// What one page should say: printed lines and one table (header row + data rows), from the answer key.
public struct ExpectedPage: Codable, Sendable {
    public let lines: [String]
    public let headers: [String]
    public let rows: [[String]]

    public init(lines: [String], headers: [String], rows: [[String]]) {
        self.lines = lines
        self.headers = headers
        self.rows = rows
    }
}

/// What the reader returned: the page text and each table as a grid of cell texts.
public struct ReadPage: Sendable, Equatable {
    public let transcript: String
    public let tables: [[[String]]]

    public init(transcript: String, tables: [[[String]]]) {
        self.transcript = transcript
        self.tables = tables
    }
}

/// Scores a read page against the answer key by code: exact text after collapsing spaces and line breaks.
public enum OCRScore {
    public struct Result: Sendable, Equatable {
        public let linesFound: Int
        public let linesTotal: Int
        public let cellsMatched: Int
        public let cellsTotal: Int
        public let missing: [String]
    }

    public static func score(_ read: ReadPage, against expected: ExpectedPage) -> Result {
        let text = normalize(read.transcript)
        var missing: [String] = []
        let linesFound = expected.lines.filter { line in
            let found = text.contains(normalize(line))
            if !found { missing.append("line: \(line)") }
            return found
        }.count

        let grid = [expected.headers] + expected.rows
        let cellsTotal = grid.reduce(0) { $0 + $1.count }
        guard let table = bestTable(read.tables, columns: expected.headers.count) else {
            return Result(linesFound: linesFound, linesTotal: expected.lines.count, cellsMatched: 0,
                          cellsTotal: cellsTotal, missing: missing + ["table: not found"])
        }
        var cellsMatched = 0
        for (row, cells) in grid.enumerated() {
            for (col, want) in cells.enumerated() {
                let got = row < table.count && col < table[row].count ? table[row][col] : "<none>"
                if normalize(got) == normalize(want) {
                    cellsMatched += 1
                } else {
                    missing.append("cell r\(row)c\(col): \(want) (read: \(got))")
                }
            }
        }
        return Result(linesFound: linesFound, linesTotal: expected.lines.count, cellsMatched: cellsMatched,
                      cellsTotal: cellsTotal, missing: missing)
    }

    /// The first table with the expected number of columns, else the first table.
    static func bestTable(_ tables: [[[String]]], columns: Int) -> [[String]]? {
        tables.first { $0.first?.count == columns } ?? tables.first
    }

    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
