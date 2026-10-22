-- Per-person marks on a chat: favorites (kept at the top of your list) and
-- hidden direct chats (archived out of it). Private: only the person who set
-- a mark ever sees it, and nothing about the chat itself changes.
--
-- Append-only, like user_names: the newest row per (user, chat, kind) wins,
-- and turning a mark off is a new row with value 0.
CREATE TABLE chat_marks (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    -- Exactly one of these: a direct chat (by friend) or a group.
    friend_id  INTEGER REFERENCES users(id),
    group_id   INTEGER REFERENCES groups(id),
    kind       TEXT    NOT NULL CHECK (kind IN ('favorite', 'hidden')),
    value      INTEGER NOT NULL CHECK (value IN (0, 1)),
    -- For 'hidden': the newest message in the chat when it was hidden. A newer
    -- message brings the chat back on its own.
    upto_id    INTEGER,
    created_at INTEGER NOT NULL,
    CHECK ((friend_id IS NULL) != (group_id IS NULL))
);
CREATE INDEX chat_marks_lookup ON chat_marks(user_id, kind, friend_id, group_id, id);
