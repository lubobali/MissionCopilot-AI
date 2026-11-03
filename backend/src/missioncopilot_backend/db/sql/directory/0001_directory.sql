-- The directory (#88): what must be found before the organization is known. A signed phone request
-- names only its device id, and an enrollment code is typed before anyone logs in. Nothing about
-- missions lives here: that is in each organization's own database.

CREATE TABLE organizations (
    id         text PRIMARY KEY CHECK (id ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
    database   text NOT NULL UNIQUE CHECK (database ~ '^[a-z][a-z0-9_]{1,62}$'),
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Only the SHA-256 of a code is stored, so a copy of this table reveals no live code (T26).
CREATE TABLE enrollment_codes (
    digest       text PRIMARY KEY CHECK (digest ~ '^[0-9a-f]{64}$'),
    org_id       text NOT NULL REFERENCES organizations (id),
    user_id      text NOT NULL,
    device_label text NOT NULL,
    expires_at   double precision NOT NULL
);

CREATE TABLE devices (
    id             uuid PRIMARY KEY,
    org_id         text NOT NULL REFERENCES organizations (id),
    user_id        text NOT NULL,
    label          text NOT NULL,
    public_key_der bytea NOT NULL,
    key_digest     text NOT NULL UNIQUE,  -- a key enrolls once, even if two requests race
    status         text NOT NULL CHECK (status IN ('pending', 'active', 'revoked')),
    enrolled_at    double precision NOT NULL,
    last_seq       bigint NOT NULL DEFAULT 0 CHECK (last_seq >= 0)
);

CREATE INDEX devices_by_org ON devices (org_id, enrolled_at);
