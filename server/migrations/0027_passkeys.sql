-- Passkeys (passkeys.rs; docs/design/passkeys.md): a third way to unlock the
-- private key, beside the password and the recovery key. The server keeps
-- the passkey's public key, to check sign-ins, and a copy of the private key
-- wrapped by a secret only the passkey can produce (WebAuthn's PRF), which it
-- can't open. Removing one marks it ended, never deletes it (Rule 1).
CREATE TABLE passkeys (
    id            INTEGER PRIMARY KEY,
    user_id       INTEGER NOT NULL REFERENCES users(id),
    -- WebAuthn's credential id, base64url without padding, as browsers give it.
    credential_id TEXT    NOT NULL,
    -- The passkey's P-256 public key, SEC1 uncompressed (65 bytes).
    public_key    BLOB    NOT NULL,
    sign_count    INTEGER NOT NULL DEFAULT 0,
    -- The private key wrapped by the passkey's PRF secret (crypto.js), base64.
    wrapped_key   TEXT    NOT NULL,
    -- Where it's kept, from its authenticator's AAGUID ("iCloud Keychain"), when known.
    provider      TEXT,
    created_at    INTEGER NOT NULL,
    last_used_at  INTEGER,
    ended_at      INTEGER,
    -- 'removed' by the person; 'key_reset' when an admin's reset code gave
    -- the account a new key, which these copies can't be.
    end_reason    TEXT CHECK (end_reason IN ('removed', 'key_reset'))
);
CREATE UNIQUE INDEX passkeys_credential ON passkeys(credential_id);
CREATE INDEX passkeys_user ON passkeys(user_id, ended_at);
