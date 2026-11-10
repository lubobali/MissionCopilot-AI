-- The officer's approval keys (#171): the public half of each phone's Face ID approval key, kept so a sync
-- can check an approval (#172). One key belongs to one phone; kept keys never change and are never removed,
-- so an old approval still checks with the key that signed it.

CREATE TABLE device_approval_keys (
    key_id         text PRIMARY KEY CHECK (key_id ~ '^[0-9a-f]{64}$'),  -- SHA-256 of the DER
    device_id      uuid NOT NULL REFERENCES devices (id),
    public_key_der bytea NOT NULL,
    added_at       double precision NOT NULL
);

CREATE INDEX device_approval_keys_by_device ON device_approval_keys (device_id, added_at);

CREATE FUNCTION device_approval_keys_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'append-only: an approval key is never changed or removed';
END
$$;

CREATE TRIGGER device_approval_keys_no_update BEFORE UPDATE ON device_approval_keys
    FOR EACH ROW EXECUTE FUNCTION device_approval_keys_append_only();
CREATE TRIGGER device_approval_keys_no_delete BEFORE DELETE ON device_approval_keys
    FOR EACH ROW EXECUTE FUNCTION device_approval_keys_append_only();
