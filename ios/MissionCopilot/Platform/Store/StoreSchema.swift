import Foundation
import GRDB

/// The store's schema, one named step per change (ADR 0008). A step already applied is never run again,
/// so existing phones upgrade in place.
enum StoreSchema {
    /// Each schema change is a new, named step; steps already applied are never run again.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-store-info") { database in
            try database.create(table: "store_info") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
        }
        // Missions and their notes (#70). The mission key is stored only wrapped; notes only sealed.
        migrator.registerMigration("v2-missions") { database in
            try database.create(table: "mission") { table in
                table.primaryKey("id", .text)
                table.column("title", .text).notNull()
                table.column("classification", .text).notNull()
                table.column("encapsulated_key", .blob).notNull()
                table.column("wrapped_key", .blob).notNull()
            }
            try database.create(table: "note") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("mission_id", .text).notNull().references("mission", onDelete: .cascade)
                table.column("sealed", .blob).notNull()
            }
        }
        // Key leases and shred records (#70, ADR 0012). A shred record outlives its mission: it is
        // reported on the next sync, so it has no foreign key that a purge would cascade through.
        migrator.registerMigration("v3-leases-and-shreds") { database in
            try database.create(table: "mission_lease") { table in
                table.primaryKey("mission_id", .text).references("mission", onDelete: .cascade)
                table.column("renewed_at", .double).notNull()
                table.column("days", .integer).notNull()
            }
            try database.create(table: "shred_record") { table in
                table.primaryKey("mission_id", .text)
                table.column("reason", .text).notNull()
                table.column("at", .double).notNull()
            }
        }
        // Evidence (#71): the signed record and the file are both sealed with the mission key, so a shred
        // makes them unreadable together; the signature and the head (a count and a hash) are not secret.
        migrator.registerMigration("v4-evidence") { database in
            try database.create(table: "evidence") { table in
                table.column("mission_id", .text).notNull().references("mission", onDelete: .cascade)
                table.column("seq", .integer).notNull()
                table.column("sealed_payload", .blob).notNull()
                table.column("signature", .blob).notNull()
                table.column("sealed_file", .blob).notNull()
                table.primaryKey(["mission_id", "seq"])
            }
            try database.create(table: "evidence_head") { table in
                table.primaryKey("mission_id", .text).references("mission", onDelete: .cascade)
                table.column("payload", .blob).notNull()
                table.column("signature", .blob).notNull()
            }
        }
        // Facts with their lineage (#72, ADR 0009). Evidence gets a label for facts to inherit. A fact's
        // first source is a required foreign key to real evidence of the same mission, so the database
        // itself refuses a fact with no source; fact_source lists every source, the first one included.
        migrator.registerMigration("v5-facts") { database in
            try database.alter(table: "evidence") { table in
                table.add(column: "classification", .text).notNull()
                    .defaults(to: Classification.officialUseOnly.rawValue)
            }
            try database.execute(sql: """
                CREATE TABLE fact (
                    id TEXT PRIMARY KEY,
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    name TEXT NOT NULL, sealed_value BLOB NOT NULL, unit TEXT,
                    rule_id TEXT NOT NULL, rule_version TEXT NOT NULL,
                    classification TEXT NOT NULL CHECK (classification IN
                        ('strictly_confidential', 'official_use_only', 'public')),
                    created_at REAL NOT NULL,
                    first_source_seq INTEGER NOT NULL,
                    FOREIGN KEY (mission_id, first_source_seq) REFERENCES evidence(mission_id, seq));
                CREATE TABLE fact_source (
                    fact_id TEXT NOT NULL REFERENCES fact(id) ON DELETE CASCADE,
                    mission_id TEXT NOT NULL, evidence_seq INTEGER NOT NULL, region TEXT,
                    PRIMARY KEY (fact_id, evidence_seq),
                    FOREIGN KEY (mission_id, evidence_seq) REFERENCES evidence(mission_id, seq) ON DELETE CASCADE);
                """)
        }
        // Report sentences (#72): a required first fact of the same mission (a two-column foreign key, so
        // the database refuses a sentence with no fact or another mission's fact); sentence_fact keeps every
        // fact in order. The text is sealed with the mission key.
        migrator.registerMigration("v6-sentences") { database in
            try database.execute(sql: """
                CREATE UNIQUE INDEX fact_by_mission ON fact (mission_id, id);
                CREATE TABLE sentence (
                    id TEXT PRIMARY KEY,
                    mission_id TEXT NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                    section TEXT NOT NULL, sealed_text BLOB NOT NULL,
                    classification TEXT NOT NULL CHECK (classification IN
                        ('strictly_confidential', 'official_use_only', 'public')),
                    created_at REAL NOT NULL,
                    first_fact_id TEXT NOT NULL,
                    FOREIGN KEY (mission_id, first_fact_id) REFERENCES fact(mission_id, id) ON DELETE CASCADE);
                CREATE TABLE sentence_fact (
                    sentence_id TEXT NOT NULL REFERENCES sentence(id) ON DELETE CASCADE,
                    mission_id TEXT NOT NULL, fact_id TEXT NOT NULL, position INTEGER NOT NULL,
                    PRIMARY KEY (sentence_id, fact_id),
                    FOREIGN KEY (mission_id, fact_id) REFERENCES fact(mission_id, id) ON DELETE CASCADE);
                """)
        }
        return migrator
    }
}
