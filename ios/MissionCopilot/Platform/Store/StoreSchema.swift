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
        // Records that cannot be changed (#72, domain invariant 5): never updated, and never deleted one by
        // one; rows go only when their whole mission is removed (purge after a shred), which the rule sees as
        // "the mission is gone". Shred records can never change. These stop bugs; a stolen database is caught
        // by the Secure Enclave signatures. The chain head is left out: it is replaced after every item.
        migrator.registerMigration("v7-append-only") { database in
            for table in ["evidence", "fact", "fact_source", "sentence", "sentence_fact"] {
                try database.execute(sql: """
                    CREATE TRIGGER \(table)_no_update BEFORE UPDATE ON \(table)
                    BEGIN SELECT RAISE(ABORT, 'append-only: \(table) rows cannot be changed'); END;
                    CREATE TRIGGER \(table)_no_delete BEFORE DELETE ON \(table)
                    WHEN EXISTS (SELECT 1 FROM mission WHERE id = OLD.mission_id)
                    BEGIN SELECT RAISE(ABORT, 'append-only: \(table) rows go only with their mission'); END;
                    """)
            }
            try database.execute(sql: """
                CREATE TRIGGER shred_record_no_update BEFORE UPDATE ON shred_record
                BEGIN SELECT RAISE(ABORT, 'append-only: shred records cannot be changed'); END;
                CREATE TRIGGER shred_record_no_delete BEFORE DELETE ON shred_record
                BEGIN SELECT RAISE(ABORT, 'append-only: shred records cannot be deleted'); END;
                """)
        }
        // The phone's audit log (#72, domain invariant 6): one hash chain for the whole store, written in the
        // same transaction as each change, never with content, and never changed or deleted, not even by a
        // purge: what happened to a mission outlives the mission.
        migrator.registerMigration("v8-audit") { database in
            try database.execute(sql: """
                CREATE TABLE audit_event (
                    seq INTEGER PRIMARY KEY, at INTEGER NOT NULL, actor TEXT NOT NULL, action TEXT NOT NULL,
                    mission_id TEXT, target_id TEXT, prev_hash TEXT NOT NULL, hash TEXT NOT NULL);
                CREATE TRIGGER audit_event_no_update BEFORE UPDATE ON audit_event
                BEGIN SELECT RAISE(ABORT, 'append-only: audit events cannot be changed'); END;
                CREATE TRIGGER audit_event_no_delete BEFORE DELETE ON audit_event
                BEGIN SELECT RAISE(ABORT, 'append-only: audit events cannot be deleted'); END;
                """)
        }
        // Mission packs (#92, ADR 0009): mission_pack is the lineage source (the signed pack: its id, version
        // and the manifest's SHA-256, the manifest itself sealed), one per mission; pack_file holds each file
        // sealed with the mission key, with its own SHA-256. A newer pack replaces both; a shred makes them
        // unreadable and purge removes them with the mission.
        migrator.registerMigration("v9-pack-files") { database in
            try database.execute(sql: """
                CREATE TABLE mission_pack (
                    mission_id TEXT PRIMARY KEY REFERENCES mission(id) ON DELETE CASCADE,
                    pack_id TEXT NOT NULL, version INTEGER NOT NULL CHECK (version >= 1),
                    manifest_sha256 TEXT NOT NULL CHECK (length(manifest_sha256) = 64),
                    sealed_manifest BLOB NOT NULL,
                    created_at REAL NOT NULL, expires_at REAL NOT NULL, imported_at REAL NOT NULL);
                CREATE TABLE pack_file (
                    mission_id TEXT NOT NULL REFERENCES mission_pack(mission_id) ON DELETE CASCADE,
                    path TEXT NOT NULL, media_type TEXT NOT NULL, size INTEGER NOT NULL CHECK (size >= 0),
                    sha256 TEXT NOT NULL CHECK (length(sha256) = 64),
                    classification TEXT NOT NULL CHECK (classification IN
                        ('strictly_confidential', 'official_use_only', 'public')),
                    sealed BLOB NOT NULL,
                    PRIMARY KEY (mission_id, path));
                """)
        }
        return migrator
    }
}
