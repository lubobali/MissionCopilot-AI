import GRDB

extension StoreSchema {
    static func registerRedFlags(in migrator: inout DatabaseMigrator) {
        // Red flags as they stood at the finish (#134, ADR 0010): written in the finish's own transaction, just
        // before the finish row, so once the walk is finished none can be added, changed or removed; they go
        // only with their mission. The detail (subject, numbers, inputs) is sealed with the mission key, and
        // every row is Strictly Confidential (docs/data-classification.md: integrity red flags).
        migrator.registerMigration("v13-red-flags") { database in
            try database.execute(sql: """
                CREATE TABLE red_flag (
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL CHECK (position >= 0),
                    rule_id TEXT NOT NULL, rule_version TEXT NOT NULL,
                    outcome TEXT NOT NULL CHECK (outcome IN ('flag', 'clear', 'notChecked')),
                    sealed_detail BLOB NOT NULL,
                    classification TEXT NOT NULL CHECK (classification = 'strictly_confidential'),
                    stored_at REAL NOT NULL,
                    PRIMARY KEY (mission_id, position));
                CREATE TRIGGER red_flag_after_finish BEFORE INSERT ON red_flag
                WHEN EXISTS (SELECT 1 FROM site_walk_finished f WHERE f.mission_id = NEW.mission_id)
                BEGIN SELECT RAISE(ABORT, 'site walk finished: red flags cannot be added'); END;
                CREATE TRIGGER red_flag_no_update BEFORE UPDATE ON red_flag
                BEGIN SELECT RAISE(ABORT, 'append-only: a red flag cannot be changed'); END;
                CREATE TRIGGER red_flag_no_delete BEFORE DELETE ON red_flag
                WHEN EXISTS (SELECT 1 FROM mission WHERE id = OLD.mission_id)
                BEGIN SELECT RAISE(ABORT, 'append-only: a red flag goes only with its mission'); END;
                """)
        }
    }
}
