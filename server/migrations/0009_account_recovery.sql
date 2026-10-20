-- Recovery keys (F2): a second copy of the private key, wrapped by a key the
-- person saved, and Argon2 of the auth key derived from it. The server never
-- sees the recovery key itself.
ALTER TABLE users ADD COLUMN recovery_hash TEXT;
ALTER TABLE users ADD COLUMN recovery_wrapped_key TEXT;
ALTER TABLE users ADD COLUMN recovery_set_at INTEGER;
-- When an admin reset gave this account a new key pair, so friends' apps can
-- explain the changed safety code.
ALTER TABLE users ADD COLUMN key_reset_at INTEGER;

-- Every credential an account ever had, copied here before it's replaced
-- (Rule 1). Someone who later remembers an old password could still unlock
-- the history it protected.
CREATE TABLE credential_history (
    id                   INTEGER PRIMARY KEY,
    user_id              INTEGER NOT NULL REFERENCES users(id),
    auth_hash            TEXT    NOT NULL,
    public_key           TEXT    NOT NULL,
    wrapped_private_key  TEXT    NOT NULL,
    recovery_hash        TEXT,
    recovery_wrapped_key TEXT,
    replaced_at          INTEGER NOT NULL,
    reason               TEXT    NOT NULL
        CHECK (reason IN ('password_changed', 'recovery_key_set', 'recovered', 'admin_reset'))
);
CREATE INDEX credential_history_user ON credential_history(user_id, id);

-- One-time codes an admin gives someone who lost both their password and
-- their recovery key. Only a hash is stored; the code is shown once.
CREATE TABLE reset_codes (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    code_hash  TEXT    NOT NULL,
    created_by INTEGER NOT NULL REFERENCES users(id),
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at    INTEGER,
    revoked_at INTEGER
);
CREATE INDEX reset_codes_user ON reset_codes(user_id, id);
