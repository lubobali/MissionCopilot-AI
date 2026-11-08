import GRDB

extension StoreSchema {
    /// Phase 6's field flows, in the order they were added: v13 red flags, v14 and v15 documents, v16 and v17
    /// debriefs, v18 kept questions and answers.
    static func registerFieldFlows(in migrator: inout DatabaseMigrator) {
        registerRedFlags(in: &migrator)
        registerDocuments(in: &migrator)
        registerDebriefs(in: &migrator)
        registerAskLog(in: &migrator)
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
