-- End-to-end encrypted group messages, format 3 (docs/group-encryption.md).
-- Additive only: plaintext (format 0) messages stay exactly as they are.

-- For format 3: the sender's random message id (base64, 16 bytes) and the
-- member list they encrypted for (a JSON array of user ids), which readers
-- need to check their key. The content itself goes in `body` (base64), or in
-- the pic file for pics.
ALTER TABLE group_messages ADD COLUMN client_id TEXT;
ALTER TABLE group_messages ADD COLUMN recipients TEXT;
-- A replayed message (same sender, same message id) is refused.
CREATE UNIQUE INDEX group_messages_client ON group_messages(group_id, sender_id, client_id)
    WHERE client_id IS NOT NULL;

-- Each member's wrap of a format 3 message's key: base64 of 60 bytes, only
-- ever returned to that member. Append-only, like messages.
CREATE TABLE group_message_keys (
    message_id INTEGER NOT NULL REFERENCES group_messages(id),
    user_id    INTEGER NOT NULL REFERENCES users(id),
    wrapped    TEXT    NOT NULL,
    PRIMARY KEY (message_id, user_id)
);

-- Format 3 group pics are opaque bytes the server can't see (and so can't
-- rebuild with images::clean); 0 is the old, server-visible kind.
ALTER TABLE group_pics ADD COLUMN format INTEGER NOT NULL DEFAULT 0;
