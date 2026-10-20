-- Pics in group chats, and group pictures. Like group texts, NOT end-to-end
-- encrypted yet. A group pic's bytes live in a file (FADE_PIC_DIR) until
-- everyone who was in the group when it was sent has opened it, or it expires;
-- the rows here are never deleted.

CREATE TABLE group_pics (
    id             INTEGER PRIMARY KEY,
    group_id       INTEGER NOT NULL REFERENCES groups(id),
    sender_id      INTEGER NOT NULL REFERENCES users(id),
    bytes          INTEGER NOT NULL,
    mime           TEXT    NOT NULL,
    created_at     INTEGER NOT NULL,
    expires_at     INTEGER NOT NULL,
    -- When the file was discarded, and why. NULL while it can still be opened.
    discarded_at   INTEGER,
    discard_reason TEXT CHECK (discard_reason IN ('opened', 'expired'))
);
CREATE INDEX group_pics_pending ON group_pics(discarded_at, expires_at);

CREATE TABLE group_pic_views (
    pic_id    INTEGER NOT NULL REFERENCES group_pics(id),
    user_id   INTEGER NOT NULL REFERENCES users(id),
    viewed_at INTEGER NOT NULL,
    PRIMARY KEY (pic_id, user_id)
);

-- A group message with a pic: kind 'text', usually an empty body (room for a caption later).
ALTER TABLE group_messages ADD COLUMN pic_id INTEGER REFERENCES group_pics(id);

-- Group pictures: small images kept in the database (so backups include
-- them). Every one ever set is kept; the newest is the current one.
CREATE TABLE group_avatars (
    id         INTEGER PRIMARY KEY,
    group_id   INTEGER NOT NULL REFERENCES groups(id),
    set_by     INTEGER NOT NULL REFERENCES users(id),
    image      BLOB    NOT NULL,
    mime       TEXT    NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX group_avatars_group ON group_avatars(group_id, id);
