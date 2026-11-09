import GRDB

extension StoreSchema {
    /// Phase 6's field flows, in the order they were added: v13 red flags, v14 and v15 documents, v16 and v17
    /// debriefs, v18 kept questions and answers.
    static func registerFieldFlows(in migrator: inout DatabaseMigrator) {
        registerRedFlags(in: &migrator)
        registerDocuments(in: &migrator)
        registerDebriefs(in: &migrator)
        registerAskLog(in: &migrator)
        registerReportSources(in: &migrator)
        registerReportApprovals(in: &migrator)
    }

    /// Report sources (#162): the server's signature over the pack's manifest, kept with the pack (sealed with
    /// the mission key; empty for packs imported before), so the pack can become evidence a report cites.
    static func registerReportSources(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v19-pack-signature") { database in
            try database.execute(sql: "ALTER TABLE mission_pack ADD COLUMN sealed_signature BLOB")
        }
        // Report drafts (#161): a draft is its sentences in order; never changed, gone only with its mission.
        migrator.registerMigration("v20-report-drafts") { database in
            try database.execute(sql: """
                CREATE TABLE report_draft (
                    id TEXT PRIMARY KEY,
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    language TEXT NOT NULL CHECK (language IN ('en', 'fr')),
                    created_at REAL NOT NULL);
                CREATE TABLE report_line (
                    draft_id TEXT NOT NULL REFERENCES report_draft(id) ON DELETE CASCADE,
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL CHECK (position >= 0),
                    sentence_id TEXT NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
                    PRIMARY KEY (draft_id, position));
                """)
            for table in ["report_draft", "report_line"] {
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

    /// Report approvals (#163): one per mission, of one draft, with the bytes signed, the Secure Enclave
    /// signature and the key that checks it; never changed, gone only with its mission.
    static func registerReportApprovals(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v21-report-approvals") { database in
            try database.execute(sql: """
                CREATE TABLE report_approval (
                    draft_id TEXT PRIMARY KEY REFERENCES report_draft(id) ON DELETE CASCADE,
                    mission_id TEXT NOT NULL UNIQUE REFERENCES mission(id) ON DELETE CASCADE,
                    approved_by TEXT NOT NULL,
                    approved_at REAL NOT NULL,
                    payload BLOB NOT NULL,
                    signature BLOB NOT NULL,
                    public_key BLOB NOT NULL);
                CREATE TRIGGER report_approval_no_update BEFORE UPDATE ON report_approval
                BEGIN SELECT RAISE(ABORT, 'append-only: an approval cannot be changed'); END;
                CREATE TRIGGER report_approval_no_delete BEFORE DELETE ON report_approval
                WHEN EXISTS (SELECT 1 FROM mission WHERE id = OLD.mission_id)
                BEGIN SELECT RAISE(ABORT, 'append-only: an approval goes only with its mission'); END;
                """)
        }
    }

    static func registerDebriefs(in migrator: inout DatabaseMigrator) {
        // Voice debriefs (#142, decided B): each recording is signed evidence of the same mission (a two-column
        // foreign key), with its length (at most the 5-minute limit) and language; append-only, gone only with
        // its mission.
        migrator.registerMigration("v16-debriefs") { database in
            try database.execute(sql: """
                CREATE TABLE debrief (
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    evidence_seq INTEGER NOT NULL,
                    seconds REAL NOT NULL CHECK (seconds > 0 AND seconds <= 300),
                    language TEXT NOT NULL CHECK (language IN ('en', 'fr')),
                    recorded_at REAL NOT NULL,
                    PRIMARY KEY (mission_id, evidence_seq),
                    FOREIGN KEY (mission_id, evidence_seq) REFERENCES evidence(mission_id, seq) ON DELETE CASCADE);
                CREATE TRIGGER debrief_no_update BEFORE UPDATE ON debrief
                BEGIN SELECT RAISE(ABORT, 'append-only: a debrief cannot be changed'); END;
                CREATE TRIGGER debrief_no_delete BEFORE DELETE ON debrief
                WHEN EXISTS (SELECT 1 FROM mission WHERE id = OLD.mission_id)
                BEGIN SELECT RAISE(ABORT, 'append-only: a debrief goes only with its mission'); END;
                """)
        }
        // What Apple's speech engine heard in each debrief (#142): sealed with the mission key, once per debrief
        // and engine version; append-only, gone with its mission.
        migrator.registerMigration("v17-debrief-transcripts") { database in
            try database.execute(sql: """
                CREATE TABLE debrief_transcript (
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    evidence_seq INTEGER NOT NULL, engine TEXT NOT NULL,
                    sealed_text BLOB NOT NULL, transcribed_at REAL NOT NULL,
                    PRIMARY KEY (mission_id, evidence_seq, engine),
                    FOREIGN KEY (mission_id, evidence_seq) REFERENCES debrief(mission_id, evidence_seq)
                        ON DELETE CASCADE);
                CREATE TRIGGER debrief_transcript_no_update BEFORE UPDATE ON debrief_transcript
                BEGIN SELECT RAISE(ABORT, 'append-only: a transcript cannot be changed'); END;
                CREATE TRIGGER debrief_transcript_no_delete BEFORE DELETE ON debrief_transcript
                WHEN EXISTS (SELECT 1 FROM mission WHERE id = OLD.mission_id)
                BEGIN SELECT RAISE(ABORT, 'append-only: a transcript goes only with its mission'); END;
                """)
        }
    }
}
