import Foundation
import GRDB

/// A manager's decision on one version of the report, as the server sent it (#193; server #178).
struct ReportReview: Sendable, Equatable {
    enum Decision: String, Sendable { case endorsed, sentBack = "sent_back" }

    let version: Int
    let decision: Decision
    let note: String?
    let reviewedAt: Date
}

extension StoreSchema {
    /// The three tables rebuilt with a version (old rows = version 1), and the decisions.
    private static let versionedTables = """
                CREATE TABLE report_approval_v (
                    draft_id TEXT PRIMARY KEY REFERENCES report_draft(id) ON DELETE CASCADE,
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    version INTEGER NOT NULL CHECK (version >= 1),
                    approved_by TEXT NOT NULL,
                    approved_at REAL NOT NULL,
                    payload BLOB NOT NULL,
                    signature BLOB NOT NULL,
                    public_key BLOB NOT NULL,
                    UNIQUE (mission_id, version));
                INSERT INTO report_approval_v SELECT draft_id, mission_id, 1, approved_by, approved_at, payload,
                    signature, public_key FROM report_approval;
                DROP TABLE report_approval;
                ALTER TABLE report_approval_v RENAME TO report_approval;
                CREATE TABLE report_outbox_v (
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    version INTEGER NOT NULL CHECK (version >= 1),
                    draft_id TEXT NOT NULL REFERENCES report_draft(id) ON DELETE CASCADE,
                    idempotency_key TEXT NOT NULL UNIQUE,
                    queued_at REAL NOT NULL,
                    PRIMARY KEY (mission_id, version));
                INSERT INTO report_outbox_v SELECT mission_id, 1, draft_id, idempotency_key, queued_at
                    FROM report_outbox;
                DROP TABLE report_outbox;
                ALTER TABLE report_outbox_v RENAME TO report_outbox;
                CREATE TABLE report_receipt_v (
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    version INTEGER NOT NULL CHECK (version >= 1),
                    batch_id TEXT NOT NULL,
                    received_at REAL NOT NULL,
                    PRIMARY KEY (mission_id, version));
                INSERT INTO report_receipt_v SELECT mission_id, 1, batch_id, received_at FROM report_receipt;
                DROP TABLE report_receipt;
                ALTER TABLE report_receipt_v RENAME TO report_receipt;
                CREATE TABLE report_review (
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    version INTEGER NOT NULL CHECK (version >= 1),
                    decision TEXT NOT NULL CHECK (decision IN ('endorsed', 'sent_back')),
                    note TEXT,
                    reviewed_at REAL NOT NULL,
                    PRIMARY KEY (mission_id, version));
                """

    /// Report versions (#193, step 193.1): a manager may send the report back with a note; the officer drafts
    /// again, approves with Face ID and sends the next version. The approval, the outbox and the receipt are
    /// kept per version (the old rows are version 1); a sent-back version's rows are history, never changed.
    /// The manager's decisions are kept as the server sent them, one per version, append-only.
    static func registerReportVersions(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v23-report-versions") { database in
            try database.execute(sql: versionedTables)
            for table in ["report_approval", "report_outbox", "report_receipt", "report_review"] {
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

/// The report's version and the manager's decisions (#193, steps 193.1-193.2): the current version is one more
/// than the versions sent back; only a decision on the version this phone sent is kept.
extension MissionStore {
    /// 1 for a first report; N + 1 once version N was sent back.
    func reportVersion(in mission: String) throws -> Int {
        try store.read { database in
            try Int.fetchOne(database, sql: """
                SELECT count(*) FROM report_review WHERE mission_id = ? AND decision = 'sent_back'
                """, arguments: [mission]) ?? 0
        } + 1
    }

    /// Keeps the server's decision when it is about the version this phone sent (its receipt is kept); an older
    /// version's, or one already kept, changes nothing. True when kept now.
    @discardableResult
    func keepReview(_ review: ReportReview, in mission: String) throws -> Bool {
        let version = try reportVersion(in: mission)
        guard review.version == version, try receipt(in: mission) != nil,
              try self.review(in: mission) == nil else { return false }
        try store.write { database in
            try database.execute(sql: "INSERT INTO report_review VALUES (?, ?, ?, ?, ?)", arguments: [
                mission, review.version, review.decision.rawValue, review.note,
                review.reviewedAt.timeIntervalSince1970.rounded()
            ])
        }
        return true
    }

    /// The decision on the current version, if the manager made it.
    func review(in mission: String) throws -> ReportReview? {
        try reviews(in: mission).first { $0.version == (try? reportVersion(in: mission)) }
    }

    /// Every decision, oldest first: the current version's and the sent-back ones before it.
    func reviews(in mission: String) throws -> [ReportReview] {
        try store.read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM report_review WHERE mission_id = ? ORDER BY version",
                             arguments: [mission])
        }.compactMap { row in
            ReportReview.Decision(rawValue: row["decision"]).map {
                ReportReview(version: row["version"], decision: $0, note: row["note"],
                             reviewedAt: Date(timeIntervalSince1970: row["reviewed_at"]))
            }
        }
    }

    /// The last sent-back version's note, for the report page of the version after it.
    func sentBack(in mission: String) throws -> ReportReview? {
        try reviews(in: mission).last { $0.decision == .sentBack }  // always the version before the current
    }

    /// #195: sent back, and the next version is not received yet: the officer has to answer.
    func needsResponse(in mission: String) throws -> Bool {
        try sentBack(in: mission) != nil && receipt(in: mission) == nil
    }
}
