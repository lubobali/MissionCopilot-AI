import GRDB

extension StoreSchema {
    static func registerDocuments(in migrator: inout DatabaseMigrator) {
        // Scanned documents (#138): the pages of one scan, in order, each a signed evidence record of the same
        // mission (a two-column foreign key, so a page cannot point at another mission's evidence). Pages are
        // evidence, so the scan is append-only too and goes only with its mission.
        migrator.registerMigration("v14-scans") { database in
            try database.execute(sql: """
                CREATE TABLE scan_page (
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    scan_id TEXT NOT NULL, page INTEGER NOT NULL CHECK (page >= 1),
                    evidence_seq INTEGER NOT NULL, scanned_at REAL NOT NULL,
                    PRIMARY KEY (mission_id, scan_id, page),
                    FOREIGN KEY (mission_id, evidence_seq) REFERENCES evidence(mission_id, seq) ON DELETE CASCADE);
                CREATE TRIGGER scan_page_no_update BEFORE UPDATE ON scan_page
                BEGIN SELECT RAISE(ABORT, 'append-only: a scanned page cannot be changed'); END;
                CREATE TRIGGER scan_page_no_delete BEFORE DELETE ON scan_page
                WHEN EXISTS (SELECT 1 FROM mission WHERE id = OLD.mission_id)
                BEGIN SELECT RAISE(ABORT, 'append-only: a scan goes only with its mission'); END;
                """)
        }
    }
}
