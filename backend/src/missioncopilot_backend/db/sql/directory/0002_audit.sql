-- The audit log of security events (threat T38, #88). One log for the whole server, in the directory:
-- many events come before any organization is known (a failed login, a rate limit). It holds ids,
-- never mission data, tokens or request bodies.
--
-- Append-only, enforced here: a change, removal or truncate is refused by trigger, for every login
-- including the owner. Someone who switches the trigger off is still caught by the hash chain.

CREATE TABLE audit_events (
    seq       bigint PRIMARY KEY CHECK (seq >= 0),
    at        double precision NOT NULL,
    kind      text NOT NULL,
    client    text,
    org_id    text,
    actor     text,
    subject   text,
    prev_hash text NOT NULL CHECK (prev_hash ~ '^[0-9a-f]{64}$'),
    hash      text NOT NULL CHECK (hash ~ '^[0-9a-f]{64}$')
);

CREATE FUNCTION audit_events_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit_events is append-only: % refused', TG_OP;
END
$$;

CREATE TRIGGER no_update_or_delete BEFORE UPDATE OR DELETE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION audit_events_append_only();
CREATE TRIGGER no_truncate BEFORE TRUNCATE ON audit_events
    FOR EACH STATEMENT EXECUTE FUNCTION audit_events_append_only();
