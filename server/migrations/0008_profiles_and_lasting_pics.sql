-- Profile pictures (F5). Visible to friends only, not end-to-end encrypted.
-- Every picture ever set is kept; the newest row is current. A row with no
-- image means the person removed their picture.
CREATE TABLE user_avatars (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    image      BLOB,
    mime       TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX user_avatars_user ON user_avatars(user_id, id);

-- Names (F5). When set_by = user_id, it's the person's own display name, which
-- their friends see. Otherwise it's a private nickname that only set_by sees.
-- Append-only: the newest row per (set_by, user_id) wins, and a NULL name
-- clears it.
CREATE TABLE user_names (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    set_by     INTEGER NOT NULL REFERENCES users(id),
    name       TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX user_names_lookup ON user_names(set_by, user_id, id);

-- Unopened direct pics wait in files on the data volume now (F9), so they
-- survive restarts. Each one's size, for the disk cap.
ALTER TABLE messages ADD COLUMN snap_bytes INTEGER;

-- Group pic captions (F6), revealed with the pic when it's opened.
ALTER TABLE group_pics ADD COLUMN caption TEXT;
