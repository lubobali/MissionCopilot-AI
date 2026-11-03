-- Missions and their teams, inside one organization's own database (ADR 0008, #88).
--
-- Row-level security: the server sets the caller for one transaction only
--   SELECT set_config('app.user_id', <user from the token>, true)
-- and Postgres itself shows a mission only to its team. Unset (or empty) means no one: nothing is
-- shown. FORCE makes the rule bind the table owner too; only an admin superuser bypasses it.
-- The app login has no write policy yet: missions and teams are set up by the organization's admin.

CREATE TABLE missions (
    id         text PRIMARY KEY CHECK (id ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
    title      text NOT NULL CHECK (title <> ''),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE mission_members (
    mission_id text NOT NULL REFERENCES missions (id) ON DELETE CASCADE,
    user_id    text NOT NULL CHECK (user_id <> ''),
    PRIMARY KEY (mission_id, user_id)
);

CREATE INDEX mission_members_by_user ON mission_members (user_id);

ALTER TABLE mission_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE mission_members FORCE ROW LEVEL SECURITY;
CREATE POLICY own_memberships ON mission_members FOR SELECT
    USING (user_id = current_setting('app.user_id', true));

ALTER TABLE missions ENABLE ROW LEVEL SECURITY;
ALTER TABLE missions FORCE ROW LEVEL SECURITY;
CREATE POLICY team_missions ON missions FOR SELECT
    USING (EXISTS (
        SELECT 1 FROM mission_members m
        WHERE m.mission_id = missions.id AND m.user_id = current_setting('app.user_id', true)
    ));
