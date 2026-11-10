import Foundation
import GRDB

/// The approved report waiting to go, with the key that makes every try the same batch (#173).
struct ReportOutbox: Sendable, Equatable {
    let draftId: String
    let idempotencyKey: String
    let queuedAt: Date
}

/// The server's receipt for the report (#172): its batch id and when it was received.
struct ReportReceipt: Sendable, Equatable {
    let batchId: String
    let receivedAt: Date
}

extension StoreSchema {
    /// Report sends (#173): the outbox (one approved report per mission), the server's receipt, and each
    /// evidence file the server confirmed; append-only, gone only with the mission.
    static func registerReportSends(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v22-report-sends") { database in
            try database.execute(sql: """
                CREATE TABLE report_outbox (
                    mission_id TEXT PRIMARY KEY REFERENCES mission(id) ON DELETE CASCADE,
                    draft_id TEXT NOT NULL REFERENCES report_draft(id) ON DELETE CASCADE,
                    idempotency_key TEXT NOT NULL UNIQUE,
                    queued_at REAL NOT NULL);
                CREATE TABLE report_receipt (
                    mission_id TEXT PRIMARY KEY REFERENCES mission(id) ON DELETE CASCADE,
                    batch_id TEXT NOT NULL,
                    received_at REAL NOT NULL);
                CREATE TABLE report_file_sent (
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    seq INTEGER NOT NULL,
                    PRIMARY KEY (mission_id, seq));
                """)
            for table in ["report_outbox", "report_receipt", "report_file_sent"] {
                try database.execute(sql: """
                    CREATE TRIGGER \(table)_no_update BEFORE UPDATE ON \(table)
                    BEGIN SELECT RAISE(ABORT, 'append-only: \(table) rows cannot be changed'); END;
                    CREATE TRIGGER \(table)_no_delete BEFORE DELETE ON \(table)
                    WHEN EXISTS (SELECT 1 FROM mission WHERE id = OLD.mission_id)
                    BEGIN SELECT RAISE(ABORT, 'append-only: \(table) rows go only with their mission'); END;
                    """)
            }
        }
    }
}

/// The outbox (#173, step 8.3.1; ADR 0006, threat T28): only an approved report is queued, once, with one
/// Idempotency-Key that every try reuses; the receipt and each confirmed file are kept so nothing is sent twice.
extension MissionStore {
    struct NotApproved: Error, Equatable {}

    @discardableResult
    func queueReport(in mission: String, now: Date = Date()) throws -> ReportOutbox {
        if let queued = try outbox(in: mission) { return queued }
        guard let approval = try approval(in: mission) else { throw NotApproved() }
        let queued = ReportOutbox(draftId: approval.draftId, idempotencyKey: UUID().uuidString.lowercased(),
                                  queuedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded()))
        try store.write { database in
            try database.execute(sql: "INSERT INTO report_outbox VALUES (?, ?, ?, ?)", arguments: [
                mission, queued.draftId, queued.idempotencyKey, queued.queuedAt.timeIntervalSince1970
            ])
        }
        return queued
    }

    func outbox(in mission: String) throws -> ReportOutbox? {
        try store.read { database in
            try Row.fetchOne(database, sql: "SELECT * FROM report_outbox WHERE mission_id = ?", arguments: [mission])
        }.map { row in
            ReportOutbox(draftId: row["draft_id"], idempotencyKey: row["idempotency_key"],
                         queuedAt: Date(timeIntervalSince1970: row["queued_at"]))
        }
    }

    func keepReceipt(batchId: String, receivedAt: Date, in mission: String) throws {
        try store.write { database in
            try database.execute(sql: "INSERT OR IGNORE INTO report_receipt VALUES (?, ?, ?)",
                                 arguments: [mission, batchId, receivedAt.timeIntervalSince1970])
        }
    }

    func receipt(in mission: String) throws -> ReportReceipt? {
        try store.read { database in
            try Row.fetchOne(database, sql: "SELECT * FROM report_receipt WHERE mission_id = ?",
                             arguments: [mission])
        }.map { ReportReceipt(batchId: $0["batch_id"], receivedAt: Date(timeIntervalSince1970: $0["received_at"])) }
    }

    func keepFileSent(seq: Int, in mission: String) throws {
        try store.write { database in
            try database.execute(sql: "INSERT OR IGNORE INTO report_file_sent VALUES (?, ?)", arguments: [mission, seq])
        }
    }

    func filesSent(in mission: String) throws -> [Int] {
        try store.read { database in
            try Int.fetchAll(database, sql: "SELECT seq FROM report_file_sent WHERE mission_id = ? ORDER BY seq",
                             arguments: [mission])
        }
    }
}
