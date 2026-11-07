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

    /// Reads an encoded page image (the sealed evidence file, opened in memory), on the phone, offline.
    static func read(_ image: Data) async throws -> PageReading {
        let documents = try await RecognizeDocumentsRequest().perform(on: image).map(\.document)
        return PageReading(transcript: documents.map(\.text.transcript).joined(separator: "\n"),
                           tables: documents.flatMap(\.tables).map { table in
                               table.rows.map { row in row.map(\.content.text.transcript) }
                           },
                           reader: currentReader)
    }
}

extension MissionStore {
    struct NotAScan: Error {}

    /// The page's reading: read once with Vision from its sealed file and stored sealed, then kept.
    func readPage(_ seq: Int, in mission: String, now: Date = Date()) async throws -> PageReading {
        if let kept = try reading(of: seq, in: mission) { return kept }
        let payloads = try evidence(in: mission).compactMap { record in
            try? JSONDecoder().decode(EvidencePayload.self, from: record.payload)
        }
        guard payloads.contains(where: { $0.seq == seq && $0.kind == .scan }) else { throw NotAScan() }
        let reading = try await PageReading.read(try evidenceFile(in: mission, seq: seq))
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
