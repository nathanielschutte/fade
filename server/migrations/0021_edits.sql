-- Edits to sent texts (edits.rs; plan X29). An edit is a new row: the text it
-- edits is never changed, so every version is kept (Rule 1), and the newest
-- edit is what shows. Additive only.

-- Direct texts: the new version, sealed like a format 2 text.
CREATE TABLE message_edits (
    id         INTEGER PRIMARY KEY,
    message_id INTEGER NOT NULL REFERENCES messages(id),
    ciphertext TEXT    NOT NULL,
    format     INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    client_id  TEXT
);
CREATE INDEX message_edits_message ON message_edits(message_id, id);
CREATE UNIQUE INDEX message_edits_client ON message_edits(message_id, client_id) WHERE client_id IS NOT NULL;

-- Group texts: the new version sealed with the format 3 scheme, for the same
-- members the text went to, each with their own wrap of its key.
CREATE TABLE group_message_edits (
    id         INTEGER PRIMARY KEY,
    message_id INTEGER NOT NULL REFERENCES group_messages(id),
    content    TEXT    NOT NULL,
    client_id  TEXT    NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX group_message_edits_message ON group_message_edits(message_id, id);
CREATE UNIQUE INDEX group_message_edits_client ON group_message_edits(message_id, client_id);

CREATE TABLE group_edit_keys (
    edit_id INTEGER NOT NULL REFERENCES group_message_edits(id),
    user_id INTEGER NOT NULL REFERENCES users(id),
    wrapped TEXT    NOT NULL,
    PRIMARY KEY (edit_id, user_id)
);
