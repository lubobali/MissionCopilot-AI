import Foundation
import GRDB
import Vision

/// What Apple Vision read on one scanned page (#138): its text, and each table as rows of cells.
struct PageReading: Codable, Sendable, Equatable {
    /// Vision's RecognizeDocumentsRequest (iOS 26), as proven on the iPhone in spike #15 (moved from the Lab).
    static let currentReader = "vision-recognize-documents-1"

    let transcript: String
    let tables: [[[String]]]
    let reader: String
    /// Where the text sat on the image, for the bad-crop warning (6.5.4).
    var layout: PageLayout?

    /// Reads an encoded page image (the sealed evidence file, opened in memory), on the phone, offline.
    static func read(_ image: Data) async throws -> PageReading {
        let documents = try await RecognizeDocumentsRequest().perform(on: image).map(\.document)
        let rect = { (box: NormalizedRect) in
            CGRect(origin: box.origin, size: CGSize(width: box.width, height: box.height))
        }
        let pages = documents.map { rect($0.boundingRegion.boundingBox) }
        let page = pages.max { $0.width * $0.height < $1.width * $1.height } ?? .zero
        let lines = documents.flatMap { $0.text.lines.map { rect($0.boundingRegion.boundingBox) } }
        return PageReading(transcript: documents.map(\.text.transcript).joined(separator: "\n"),
                           tables: documents.flatMap(\.tables).map { table in
                               table.rows.map { row in row.map(\.content.text.transcript) }
                           },
                           reader: currentReader, layout: PageLayout(page: page, lines: lines))
    }
}

/// Whether a scan caught more than its page (spike #15: in the darkest run the scanner took the whole monitor
/// and the model, given the extra text, returned "0 of 0 km"). Vision calls the whole image the page even
/// with other windows around it (found while testing), so the sign is the edge: a cropped page has margins,
/// a caught screen has text at its very edge. Then the officer is asked to retake it (and may still use it).
struct PageLayout: Codable, Sendable, Equatable {
    /// The edge band, as a fraction of the image: printed pages keep wider margins than this.
    static let edgeBand = 0.025
    static let smallestPage = 0.5

    let documentArea: Double
    let linesAtTheEdge: Int

    var looksCropped: Bool { documentArea < Self.smallestPage || linesAtTheEdge > 0 }

    init(documentArea: Double, linesAtTheEdge: Int) {
        self.documentArea = documentArea
        self.linesAtTheEdge = linesAtTheEdge
    }

    /// From Vision's normalized boxes (0 to 1): the page it found and every line of text on the image.
    init(page: CGRect, lines: [CGRect]) {
        let band = Self.edgeBand
        self.init(documentArea: Double(page.width * page.height),
                  linesAtTheEdge: lines.filter { line in
                      line.minX < band || line.minY < band || line.maxX > 1 - band || line.maxY > 1 - band
                  }.count)
    }
}

extension MissionStore {
    struct NotAScan: Error {}

    /// The page's reading: read once with Vision from its sealed file and stored sealed, then kept.
    func readPage(_ seq: Int, in mission: String, now: Date = Date(),
                  read: @Sendable (Data) async throws -> PageReading = PageReading.read) async throws -> PageReading {
        if let kept = try reading(of: seq, in: mission) { return kept }
        let payloads = try evidence(in: mission).compactMap { record in
            try? JSONDecoder().decode(EvidencePayload.self, from: record.payload)
        }
        guard payloads.contains(where: { $0.seq == seq && $0.kind == .scan }) else { throw NotAScan() }
        let reading = try await read(try evidenceFile(in: mission, seq: seq))
        let sealed = try MissionData.seal(try JSONEncoder().encode(reading), with: missionKey(for: mission))
        try store.write { database in
            try database.execute(sql: "INSERT INTO page_reading VALUES (?, ?, ?, ?, ?)",
                                 arguments: [mission, seq, reading.reader, sealed, now.timeIntervalSince1970])
            try EncryptedStore.appendAudit(AuditEntry(action: .pageRead, actor: actor, mission: mission,
                                                      target: "\(seq) \(reading.reader)", time: now), in: database)
        }
        return reading
    }

    /// The page's stored reading by the current reader, or nil if it has not been read yet.
    func reading(of seq: Int, in mission: String) throws -> PageReading? {
        let sealed = try store.read { database in
            try Data.fetchOne(database, sql: """
                SELECT sealed_reading FROM page_reading WHERE mission_id = ? AND evidence_seq = ? AND reader = ?
                """, arguments: [mission, seq, PageReading.currentReader])
        }
        guard let sealed else { return nil }
        return try JSONDecoder().decode(PageReading.self,
                                        from: try MissionData.open(sealed, with: missionKey(for: mission)))
    }
}
