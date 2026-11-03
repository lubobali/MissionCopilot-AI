-- Mission packs (#89, threat T51), in the organization's own database.
--
-- packs:         one row per published version: the manifest exactly as signed, and its signature
-- pack_files:    each file once, by its SHA-256; Postgres checks the hash against the bytes itself
-- pack_contents: which file sits at which path in which version
--
-- Read only by the mission's team (forced row-level security, as for missions). Published by an
-- operator as the admin, never by the app login (it has no write policy). Nothing published can be
-- changed or removed (append-only triggers), and a mission's version only goes up by one, so a
-- phone can refuse an older pack (rollback) and still finish downloading the files of the version
-- it started.

CREATE TABLE packs (
    mission_id text NOT NULL REFERENCES missions (id),
    version    integer NOT NULL CHECK (version >= 1),
    pack_id    uuid NOT NULL UNIQUE,
    manifest   bytea NOT NULL,
    signature  jsonb NOT NULL,
    key_id     text NOT NULL CHECK (key_id ~ '^[0-9a-f]{16}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (mission_id, version)
);

CREATE TABLE pack_files (
    sha256 text PRIMARY KEY CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    data   bytea NOT NULL CHECK (octet_length(data) <= 20971520),
    CHECK (sha256 = encode(sha256(data), 'hex'))
);

CREATE TABLE pack_contents (
    mission_id text NOT NULL,
    version    integer NOT NULL,
    path       text NOT NULL,
    sha256     text NOT NULL REFERENCES pack_files (sha256),
    PRIMARY KEY (mission_id, version, path),
    FOREIGN KEY (mission_id, version) REFERENCES packs (mission_id, version)
);

CREATE INDEX pack_contents_by_file ON pack_contents (sha256, mission_id);

-- The next version is exactly one more than the last; the admin publishing sees every row.
CREATE FUNCTION packs_next_version() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    last integer;
BEGIN
    SELECT coalesce(max(version), 0) INTO last FROM packs WHERE mission_id = NEW.mission_id;
    IF NEW.version <> last + 1 THEN
        RAISE EXCEPTION 'pack version % for mission % must be %', NEW.version, NEW.mission_id, last + 1;
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER next_version BEFORE INSERT ON packs
    FOR EACH ROW EXECUTE FUNCTION packs_next_version();

CREATE FUNCTION packs_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only: % refused', TG_TABLE_NAME, TG_OP;
END
$$;
CREATE TRIGGER no_update_or_delete BEFORE UPDATE OR DELETE ON packs
    FOR EACH ROW EXECUTE FUNCTION packs_append_only();
CREATE TRIGGER no_truncate BEFORE TRUNCATE ON packs
    FOR EACH STATEMENT EXECUTE FUNCTION packs_append_only();
CREATE TRIGGER no_update_or_delete BEFORE UPDATE OR DELETE ON pack_contents
    FOR EACH ROW EXECUTE FUNCTION packs_append_only();
CREATE TRIGGER no_truncate BEFORE TRUNCATE ON pack_contents
    FOR EACH STATEMENT EXECUTE FUNCTION packs_append_only();
CREATE TRIGGER no_update_or_delete BEFORE UPDATE OR DELETE ON pack_files
    FOR EACH ROW EXECUTE FUNCTION packs_append_only();
CREATE TRIGGER no_truncate BEFORE TRUNCATE ON pack_files
    FOR EACH STATEMENT EXECUTE FUNCTION packs_append_only();

ALTER TABLE packs ENABLE ROW LEVEL SECURITY;
ALTER TABLE packs FORCE ROW LEVEL SECURITY;
CREATE POLICY team_packs ON packs FOR SELECT
    USING (EXISTS (
        SELECT 1 FROM mission_members m
        WHERE m.mission_id = packs.mission_id AND m.user_id = current_setting('app.user_id', true)
    ));

ALTER TABLE pack_contents ENABLE ROW LEVEL SECURITY;
ALTER TABLE pack_contents FORCE ROW LEVEL SECURITY;
CREATE POLICY team_contents ON pack_contents FOR SELECT
    USING (EXISTS (
        SELECT 1 FROM mission_members m
        WHERE m.mission_id = pack_contents.mission_id
          AND m.user_id = current_setting('app.user_id', true)
    ));

-- A file is visible when a pack the caller's team may read holds it (pack_contents is filtered
-- by its own policy first).
ALTER TABLE pack_files ENABLE ROW LEVEL SECURITY;
ALTER TABLE pack_files FORCE ROW LEVEL SECURITY;
CREATE POLICY team_files ON pack_files FOR SELECT
    USING (EXISTS (SELECT 1 FROM pack_contents c WHERE c.sha256 = pack_files.sha256));
