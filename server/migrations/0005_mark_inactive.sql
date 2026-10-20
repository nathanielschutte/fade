-- Nothing in the database is deleted (CLAUDE.md, Rule 1). Instead of removing
-- a row when something ends, these columns record when and how it ended, and
-- friend_events keeps the full history, so reusing a row (re-friending, asking
-- again after a decline) loses nothing.

-- Unfriending sets these; a current friendship has ended_at NULL.
ALTER TABLE friendships ADD COLUMN ended_at INTEGER;
ALTER TABLE friendships ADD COLUMN ended_by INTEGER REFERENCES users(id);

-- A pending request has resolved_at NULL.
ALTER TABLE friend_requests ADD COLUMN resolved_at INTEGER;
ALTER TABLE friend_requests ADD COLUMN resolution TEXT
    CHECK (resolution IN ('accepted', 'declined', 'canceled'));

-- Signing out sets this; expired sessions simply stay expired.
ALTER TABLE sessions ADD COLUMN revoked_at INTEGER;

-- Append-only: every friendship change, in order.
CREATE TABLE friend_events (
    id         INTEGER PRIMARY KEY,
    actor_id   INTEGER NOT NULL REFERENCES users(id),
    other_id   INTEGER NOT NULL REFERENCES users(id),
    kind       TEXT    NOT NULL
               CHECK (kind IN ('requested', 'accepted', 'declined', 'canceled', 'unfriended')),
    created_at INTEGER NOT NULL
);
CREATE INDEX friend_events_actor ON friend_events(actor_id, created_at);
CREATE INDEX friend_events_other ON friend_events(other_id, created_at);
