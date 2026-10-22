-- Muting a chat (X3): no notifications and no unread dot from it, for a
-- while or until turned back on. Private to whoever mutes, like chat_marks.
-- Append-only: the newest row per (user, chat) wins; value 0 unmutes.
CREATE TABLE chat_mutes (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    friend_id  INTEGER REFERENCES users(id),
    group_id   INTEGER REFERENCES groups(id),
    value      INTEGER NOT NULL CHECK (value IN (0, 1)),
    -- When a mute ends by itself (Unix seconds); NULL means until turned off.
    until_at   INTEGER,
    created_at INTEGER NOT NULL,
    CHECK ((friend_id IS NULL) != (group_id IS NULL))
);
CREATE INDEX chat_mutes_lookup ON chat_mutes(user_id, friend_id, group_id, id);
