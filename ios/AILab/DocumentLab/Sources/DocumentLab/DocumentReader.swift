import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads a page image on device with Vision's RecognizeDocumentsRequest (iOS 26+): text and tables.
@available(iOS 26.0, macOS 26.0, *)
public enum DocumentReader {
    public struct Timed: Sendable {
        public let page: ReadPage
        public let milliseconds: Double
    }

    /// Encoded image (PNG/JPEG); orientation comes from the file.
    public static func read(imageData: Data) async throws -> Timed {
        let start = Date()
        let observations = try await RecognizeDocumentsRequest().perform(on: imageData)
        return Timed(page: page(from: observations), milliseconds: Date().timeIntervalSince(start) * 1000)
    }

    /// Camera image: pass its orientation, or a sideways photo reads as noise.
    public static func read(cgImage: CGImage, orientation: CGImagePropertyOrientation) async throws -> Timed {
        let start = Date()
        let observations = try await RecognizeDocumentsRequest().perform(on: cgImage, orientation: orientation)
        return Timed(page: page(from: observations), milliseconds: Date().timeIntervalSince(start) * 1000)
    }

    private static func page(from observations: [DocumentObservation]) -> ReadPage {
        let documents = observations.map(\.document)
        let transcript = documents.map(\.text.transcript).joined(separator: "\n")
        let tables = documents.flatMap(\.tables).map { table in
            table.rows.map { row in row.map(\.content.text.transcript) }
        }
        return ReadPage(transcript: transcript, tables: tables)
    }
}
