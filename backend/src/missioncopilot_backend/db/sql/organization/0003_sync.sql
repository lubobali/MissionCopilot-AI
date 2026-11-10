-- Synced reports (#172, ADR 0006 and 0009): what a phone sends after the officer approved a report with
-- Face ID. The evidence chain as signed on the phone, each head it sent, the facts with their sources,
-- the approved draft's sentences with the approval, and a receipt per batch. Everything append-only; the
-- mission's team may add and read its own rows (row-level security, as for missions and packs).

CREATE TABLE evidence (
    mission_id   text NOT NULL REFERENCES missions (id),
    seq          integer NOT NULL CHECK (seq > 0),
    payload      bytea NOT NULL,  -- the exact bytes the phone signed
    signature    bytea NOT NULL,
    kind         text NOT NULL CHECK (kind IN ('photo', 'scan', 'audio', 'pack', 'walk')),
    content_hash text NOT NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),
    received_at  double precision NOT NULL,
    PRIMARY KEY (mission_id, seq)
);

CREATE TABLE evidence_heads (
    mission_id  text NOT NULL REFERENCES missions (id),
    count       integer NOT NULL CHECK (count > 0),
    payload     bytea NOT NULL,
    signature   bytea NOT NULL,
    received_at double precision NOT NULL,
    PRIMARY KEY (mission_id, count)  -- the newest head is the highest count
);

CREATE TABLE facts (
    mission_id     text NOT NULL REFERENCES missions (id),
    id             text NOT NULL,
    name           text NOT NULL,
    value          text NOT NULL,
    unit           text,
    rule_id        text NOT NULL,
    rule_version   text NOT NULL,
    classification text NOT NULL
        CHECK (classification IN ('strictly_confidential', 'official_use_only', 'public')),
    PRIMARY KEY (mission_id, id)
);

CREATE TABLE fact_sources (
    mission_id text NOT NULL,
    fact_id    text NOT NULL,
    seq        integer NOT NULL,
    region     text,
    PRIMARY KEY (mission_id, fact_id, seq),
    FOREIGN KEY (mission_id, fact_id) REFERENCES facts (mission_id, id),
    FOREIGN KEY (mission_id, seq) REFERENCES evidence (mission_id, seq)  -- a fact's evidence is here
);

CREATE TABLE reports (
    mission_id         text PRIMARY KEY REFERENCES missions (id),  -- one approved report per mission
    draft_id           text NOT NULL UNIQUE,
    language           text NOT NULL CHECK (language IN ('en', 'fr')),
    approved_by        text NOT NULL,
    approved_at        double precision NOT NULL,
    approval_payload   bytea NOT NULL,  -- the exact bytes signed after Face ID
    approval_signature bytea NOT NULL,
    approval_key_id    text NOT NULL CHECK (approval_key_id ~ '^[0-9a-f]{64}$'),
    device_id          uuid NOT NULL,
    received_at        double precision NOT NULL
);

CREATE TABLE report_sentences (
    mission_id     text NOT NULL REFERENCES reports (mission_id),
    position       integer NOT NULL CHECK (position >= 0),
    sentence_id    text NOT NULL,
    section        text NOT NULL,
    text           text NOT NULL,
    classification text NOT NULL
        CHECK (classification IN ('strictly_confidential', 'official_use_only', 'public')),
    fact_ids       text[] NOT NULL CHECK (cardinality(fact_ids) > 0),  -- no sentence without facts
    PRIMARY KEY (mission_id, position)
);

CREATE TABLE sync_receipts (
    idempotency_key uuid PRIMARY KEY,
    mission_id      text NOT NULL REFERENCES missions (id),
    batch_id        uuid NOT NULL UNIQUE,
    draft_id        text NOT NULL,
    item_count      integer NOT NULL CHECK (item_count >= 0),
    received_at     double precision NOT NULL
);

CREATE FUNCTION sync_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'append-only: synced rows are never changed or removed';
END
$$;

DO $$
DECLARE
    name text;
BEGIN
    FOREACH name IN ARRAY ARRAY['evidence', 'evidence_heads', 'facts', 'fact_sources', 'reports',
                                'report_sentences', 'sync_receipts'] LOOP
        EXECUTE format('CREATE TRIGGER no_update_or_delete BEFORE UPDATE OR DELETE ON %I'
                       ' FOR EACH ROW EXECUTE FUNCTION sync_append_only()', name);
        EXECUTE format('CREATE TRIGGER no_truncate BEFORE TRUNCATE ON %I'
                       ' FOR EACH STATEMENT EXECUTE FUNCTION sync_append_only()', name);
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', name);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', name);
        EXECUTE format('CREATE POLICY team_reads ON %I FOR SELECT USING (EXISTS (SELECT 1 FROM'
                       ' mission_members m WHERE m.mission_id = %I.mission_id'
                       ' AND m.user_id = current_setting(''app.user_id'', true)))', name, name);
        EXECUTE format('CREATE POLICY team_adds ON %I FOR INSERT WITH CHECK (EXISTS (SELECT 1 FROM'
                       ' mission_members m WHERE m.mission_id = %I.mission_id'
                       ' AND m.user_id = current_setting(''app.user_id'', true)))', name, name);
    END LOOP;
END
$$;
