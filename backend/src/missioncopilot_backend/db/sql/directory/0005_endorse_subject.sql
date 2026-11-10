-- An endorsement's challenge names what it endorses (#178, step 8.8.2): the mission, the report's
-- version and the SHA-256 of the officer's approval. A challenge for one report cannot endorse another.

ALTER TABLE webauthn_challenges ADD COLUMN subject text;
