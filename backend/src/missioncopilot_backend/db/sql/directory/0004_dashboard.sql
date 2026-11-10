-- The dashboard's people and their sign-in (#174): managers invited by the operator, their passkeys
-- (Touch ID on the Mac), one-time challenges and sessions. Codes, challenges and session tokens are
-- kept only as their SHA-256. A passkey's sign count is the only value that may change.

CREATE TABLE dashboard_users (
    id         uuid PRIMARY KEY,
    org_id     text NOT NULL REFERENCES organizations (id),
    user_id    text NOT NULL CHECK (user_id <> ''),
    name       text NOT NULL CHECK (name <> ''),
    roles      text[] NOT NULL,
    created_at double precision NOT NULL,
    UNIQUE (org_id, user_id)
);

CREATE TABLE dashboard_invites (
    digest     text PRIMARY KEY CHECK (digest ~ '^[0-9a-f]{64}$'),
    user_ref   uuid NOT NULL REFERENCES dashboard_users (id),
    expires_at double precision NOT NULL
);

CREATE TABLE webauthn_challenges (
    digest     text PRIMARY KEY CHECK (digest ~ '^[0-9a-f]{64}$'),
    purpose    text NOT NULL CHECK (purpose IN ('register', 'sign_in', 'endorse')),
    user_ref   uuid REFERENCES dashboard_users (id),
    expires_at double precision NOT NULL
);

CREATE TABLE passkeys (
    credential_id bytea PRIMARY KEY,
    user_ref      uuid NOT NULL REFERENCES dashboard_users (id),
    public_key    bytea NOT NULL,
    sign_count    bigint NOT NULL CHECK (sign_count >= 0),
    added_at      double precision NOT NULL
);

CREATE TABLE dashboard_sessions (
    digest     text PRIMARY KEY CHECK (digest ~ '^[0-9a-f]{64}$'),
    user_ref   uuid NOT NULL REFERENCES dashboard_users (id),
    expires_at double precision NOT NULL
);

CREATE INDEX passkeys_by_user ON passkeys (user_ref);
