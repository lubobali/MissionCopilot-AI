-- Evidence files (#172, step 8.2.4): the photo, scanned page or recording behind a received evidence item,
-- kept only when its SHA-256 is the contentHash the phone signed. Append-only; the mission's team only.

CREATE TABLE evidence_files (
    mission_id  text NOT NULL,
    seq         integer NOT NULL,
    data        bytea NOT NULL,
    received_at double precision NOT NULL,
    PRIMARY KEY (mission_id, seq),
    FOREIGN KEY (mission_id, seq) REFERENCES evidence (mission_id, seq)
);

CREATE TRIGGER no_update_or_delete BEFORE UPDATE OR DELETE ON evidence_files
    FOR EACH ROW EXECUTE FUNCTION sync_append_only();
CREATE TRIGGER no_truncate BEFORE TRUNCATE ON evidence_files
    FOR EACH STATEMENT EXECUTE FUNCTION sync_append_only();
ALTER TABLE evidence_files ENABLE ROW LEVEL SECURITY;
ALTER TABLE evidence_files FORCE ROW LEVEL SECURITY;
CREATE POLICY team_reads ON evidence_files FOR SELECT USING (EXISTS (SELECT 1 FROM mission_members m
    WHERE m.mission_id = evidence_files.mission_id AND m.user_id = current_setting('app.user_id', true)));
CREATE POLICY team_adds ON evidence_files FOR INSERT WITH CHECK (EXISTS (SELECT 1 FROM mission_members m
    WHERE m.mission_id = evidence_files.mission_id AND m.user_id = current_setting('app.user_id', true)));
