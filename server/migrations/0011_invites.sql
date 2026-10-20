-- Invite links (F14). Anyone can make a link that signs a new person up (no
-- invite code needed) and makes them friends, or adds someone who already has
-- an account. Only a hash of each link's token is stored. Links expire and
-- can be revoked; nothing is deleted.
CREATE TABLE invites (
    id         INTEGER PRIMARY KEY,
    created_by INTEGER NOT NULL REFERENCES users(id),
    token_hash TEXT    NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    max_uses   INTEGER NOT NULL,
    revoked_at INTEGER
);
CREATE INDEX invites_creator ON invites(created_by, id);

-- Who came in through which link, and how.
CREATE TABLE invite_uses (
    id         INTEGER PRIMARY KEY,
    invite_id  INTEGER NOT NULL REFERENCES invites(id),
    user_id    INTEGER NOT NULL REFERENCES users(id),
    kind       TEXT    NOT NULL CHECK (kind IN ('signed_up', 'added')),
    created_at INTEGER NOT NULL
);
CREATE INDEX invite_uses_invite ON invite_uses(invite_id);
