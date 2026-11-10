-- Report versions and the manager's decision (#178, step 8.8.0). A manager either endorses a received
-- report or sends it back with a note; the officer then approves and sends a new version. Each version
-- is kept as it came (append-only, like every synced row); the newest is the one to review. One final
-- decision per version. A manager on the mission's own team cannot decide (separation of duties):
-- Postgres refuses it, whatever the server asks.

ALTER TABLE report_sentences DROP CONSTRAINT report_sentences_mission_id_fkey;
ALTER TABLE report_sentences DROP CONSTRAINT report_sentences_pkey;
ALTER TABLE reports DROP CONSTRAINT reports_pkey;
ALTER TABLE reports ADD COLUMN version integer NOT NULL DEFAULT 1 CHECK (version > 0);
ALTER TABLE reports ADD PRIMARY KEY (mission_id, version);
ALTER TABLE report_sentences ADD COLUMN version integer NOT NULL DEFAULT 1;
ALTER TABLE report_sentences ADD PRIMARY KEY (mission_id, version, position);
ALTER TABLE report_sentences ADD FOREIGN KEY (mission_id, version) REFERENCES reports (mission_id, version);

CREATE TABLE report_reviews (
    mission_id     text NOT NULL,
    version        integer NOT NULL,
    decision       text NOT NULL CHECK (decision IN ('endorsed', 'sent_back')),
    note           text CHECK (note IS NULL OR char_length(note) BETWEEN 1 AND 500),
    reviewer_id    text NOT NULL,  -- the manager's user id (app.user_id)
    reviewer_name  text NOT NULL,
    reviewed_at    double precision NOT NULL,
    approval_hash  text NOT NULL CHECK (approval_hash ~ '^[0-9a-f]{64}$'),  -- what was decided on
    credential_id  bytea,  -- the passkey assertion behind an endorsement
    authenticator_data bytea,
    client_data    bytea,
    signature      bytea,
    PRIMARY KEY (mission_id, version),  -- final: one decision per version
    FOREIGN KEY (mission_id, version) REFERENCES reports (mission_id, version),
    CHECK (decision <> 'sent_back' OR note IS NOT NULL),
    CHECK (decision <> 'endorsed' OR (credential_id IS NOT NULL AND authenticator_data IS NOT NULL
                                      AND client_data IS NOT NULL AND signature IS NOT NULL))
);

CREATE TRIGGER no_update_or_delete BEFORE UPDATE OR DELETE ON report_reviews
    FOR EACH ROW EXECUTE FUNCTION sync_append_only();
CREATE TRIGGER no_truncate BEFORE TRUNCATE ON report_reviews
    FOR EACH STATEMENT EXECUTE FUNCTION sync_append_only();
ALTER TABLE report_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE report_reviews FORCE ROW LEVEL SECURITY;
CREATE POLICY team_reads ON report_reviews FOR SELECT USING (EXISTS (SELECT 1 FROM mission_members m
    WHERE m.mission_id = report_reviews.mission_id AND m.user_id = current_setting('app.user_id', true)));
CREATE POLICY manager_reads ON report_reviews FOR SELECT
    USING (current_setting('app.role', true) = 'manager');
CREATE POLICY manager_decides ON report_reviews FOR INSERT WITH CHECK (
    current_setting('app.role', true) = 'manager'
    AND reviewer_id = current_setting('app.user_id', true)
    AND NOT EXISTS (SELECT 1 FROM mission_members m WHERE m.mission_id = report_reviews.mission_id
                    AND m.user_id = current_setting('app.user_id', true)));
