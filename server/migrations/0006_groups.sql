-- Group chats. Version 1 is NOT end-to-end encrypted: group messages are
-- stored as plain text (format 0), and every client says so in the group.
-- Nothing here is deleted: leaving or being removed sets left_at, and
-- membership changes are recorded as 'event' messages in the group itself.

CREATE TABLE groups (
    id         INTEGER PRIMARY KEY,
    name       TEXT    NOT NULL,
    created_by INTEGER NOT NULL REFERENCES users(id),
    created_at INTEGER NOT NULL
);

CREATE TABLE group_members (
    group_id     INTEGER NOT NULL REFERENCES groups(id),
    user_id      INTEGER NOT NULL REFERENCES users(id),
    role         TEXT    NOT NULL CHECK (role IN ('owner', 'member')),
    added_by     INTEGER REFERENCES users(id),
    -- When the current membership started (rejoining starts a new one).
    joined_at    INTEGER NOT NULL,
    -- Set when they leave or are removed; NULL while they're a member.
    left_at      INTEGER,
    removed_by   INTEGER REFERENCES users(id),
    -- They see group messages with ids above this: the newest message when
    -- the current membership started, so history begins at their (re)join.
    visible_after_id INTEGER NOT NULL DEFAULT 0,
    -- Highest group message id they've read, for unread counts.
    last_read_id INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (group_id, user_id)
);
CREATE INDEX group_members_user ON group_members(user_id);

CREATE TABLE group_messages (
    id         INTEGER PRIMARY KEY,
    group_id   INTEGER NOT NULL REFERENCES groups(id),
    sender_id  INTEGER NOT NULL REFERENCES users(id),
    -- 'text' is something someone wrote; 'event' is a membership or name
    -- change, with a JSON body like {"type":"added","target":5}.
    kind       TEXT    NOT NULL CHECK (kind IN ('text', 'event')),
    body       TEXT    NOT NULL,
    -- 0 = not encrypted. A future end-to-end encrypted scheme gets 1+.
    format     INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
);
CREATE INDEX group_messages_group ON group_messages(group_id, id);
