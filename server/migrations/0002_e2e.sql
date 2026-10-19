-- End-to-end encryption. Starts fresh: accounts from before this used raw
-- passwords for sign-in and stored messages in plaintext, so nothing carries over.

DROP TABLE messages;
DROP TABLE friendships;
DROP TABLE friend_requests;
DROP TABLE sessions;
DROP TABLE users;

-- `auth_hash` is Argon2 of a key the client derives from the password, never
-- the password itself. The private key is wrapped (AES-GCM) with a second key
-- derived from the same password, so the server can't unwrap it.
CREATE TABLE users (
    id                  INTEGER PRIMARY KEY,
    username            TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    auth_hash           TEXT    NOT NULL,
    public_key          TEXT    NOT NULL,
    wrapped_private_key TEXT    NOT NULL,
    created_at          INTEGER NOT NULL
);

-- Only a SHA-256 of each session token is stored, so a leaked DB can't be replayed.
CREATE TABLE sessions (
    token_hash TEXT    PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);
CREATE INDEX sessions_user ON sessions(user_id);

CREATE TABLE friend_requests (
    from_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    to_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (from_id, to_id)
);
CREATE INDEX friend_requests_to ON friend_requests(to_id);

-- One row per friendship, stored with the smaller id first.
CREATE TABLE friendships (
    user_lo    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user_hi    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (user_lo, user_hi),
    CHECK (user_lo < user_hi)
);
CREATE INDEX friendships_hi ON friendships(user_hi);

-- Texts hold ciphertext only (base64 of IV || AES-GCM output). Snap rows hold
-- metadata only; the encrypted image lives in server RAM until viewed or expired.
CREATE TABLE messages (
    id           INTEGER PRIMARY KEY,
    sender_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind         TEXT    NOT NULL CHECK (kind IN ('text', 'snap')),
    ciphertext   TEXT,
    snap_state   TEXT    CHECK (snap_state IN ('pending', 'opened', 'expired')),
    created_at   INTEGER NOT NULL,
    read_at      INTEGER
);
CREATE INDEX messages_pair ON messages(sender_id, recipient_id, id);
