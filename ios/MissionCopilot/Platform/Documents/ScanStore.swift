import Foundation
import GRDB
import UIKit

/// One scan: its pages in order, each the seq of a signed evidence record (#138).
struct DocumentScan: Sendable, Equatable, Identifiable {
    let id: String
    let pages: [Int]
    let scannedAt: Date
}

extension MissionStore {
    struct NoPages: Error {}

    /// Each page re-encoded like a site photo (no metadata in the file) and signed into the mission's chain as
    /// kind scan with the phone's key, then the scan recorded with its pages in order. Documents are not the
    /// walk: a finished walk does not stop a scan.
    @discardableResult
    func addScan(_ pages: [UIImage], to mission: String, signer: any EvidenceSigner,
                 now: Date = Date()) throws -> DocumentScan {
        guard !pages.isEmpty else { throw NoPages() }
        let seqs = try pages.map { page in
            let capture = Capture(file: try SitePhoto.prepare(page), kind: .scan, capturedAt: now,
                                  clockSource: .device, location: nil)
            let record = try addEvidence(capture, to: mission, signer: signer)
            return try JSONDecoder().decode(EvidencePayload.self, from: record.payload).seq
        }
        // The time as the store keeps it (seconds since 1970), so a scan read back is equal to this one.
        let scan = DocumentScan(id: UUID().uuidString.lowercased(), pages: seqs,
                                scannedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970))
        try store.write { database in
            for (index, seq) in seqs.enumerated() {
                try database.execute(sql: "INSERT INTO scan_page VALUES (?, ?, ?, ?, ?)",
                                     arguments: [mission, scan.id, index + 1, seq,
                                                 scan.scannedAt.timeIntervalSince1970])
            }
            try EncryptedStore.appendAudit(AuditEntry(action: .documentScanned, actor: actor, mission: mission,
                                                      target: "\(scan.id) \(seqs.count) pages", time: now),
                                           in: database)
        }
        return scan
    }

    /// The mission's scans in the order they were made (two in the same second keep their order), each with
    /// its pages in order.
    func scans(in mission: String) throws -> [DocumentScan] {
        let rows = try store.read { database in
            try Row.fetchAll(database, sql: """
                SELECT scan_id, page, evidence_seq, scanned_at FROM scan_page WHERE mission_id = ?
                ORDER BY rowid
                """, arguments: [mission])
        }
        var order: [String] = []
        var pages: [String: [Int]] = [:]
        var times: [String: Date] = [:]
        for row in rows {
            let id: String = row["scan_id"]
            if pages[id] == nil { order.append(id) }
            pages[id, default: []].append(row["evidence_seq"])
            times[id] = Date(timeIntervalSince1970: row["scanned_at"])
        }
        return order.map { DocumentScan(id: $0, pages: pages[$0] ?? [], scannedAt: times[$0] ?? .distantPast) }
    }
}
