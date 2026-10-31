import Foundation
import Vision

/// Reads a page image on device with Vision's RecognizeDocumentsRequest (iOS 26+): text and tables.
@available(iOS 26.0, macOS 26.0, *)
public enum DocumentReader {
    public struct Timed: Sendable {
        public let page: ReadPage
        public let milliseconds: Double
    }

    public static func read(imageData: Data) async throws -> Timed {
        let start = Date()
        let observations = try await RecognizeDocumentsRequest().perform(on: imageData)
        let documents = observations.map(\.document)
        let transcript = documents.map(\.text.transcript).joined(separator: "\n")
        let tables = documents.flatMap(\.tables).map { table in
            table.rows.map { row in row.map(\.content.text.transcript) }
        }
        return Timed(page: ReadPage(transcript: transcript, tables: tables),
                     milliseconds: Date().timeIntervalSince(start) * 1000)
    }
}
