-- Typing and "active now" (F12): whether friends see when you're active or
-- typing. Hiding yours hides theirs from you too.
ALTER TABLE users ADD COLUMN share_activity INTEGER NOT NULL DEFAULT 1;

-- Push notifications (F10). One row per browser that turned notifications
-- on, tied to the session that did it: signing out (or the session ending)
-- stops its notifications. Rows are marked ended, never deleted.
CREATE TABLE push_subscriptions (
    id           INTEGER PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES users(id),
    session_hash TEXT    NOT NULL,
    endpoint     TEXT    NOT NULL,
    p256dh       TEXT    NOT NULL,
    auth         TEXT    NOT NULL,
    created_at   INTEGER NOT NULL,
    ended_at     INTEGER,
    end_reason   TEXT CHECK (end_reason IN ('turned_off', 'replaced', 'signed_out', 'gone'))
);
CREATE INDEX push_subscriptions_user ON push_subscriptions(user_id, ended_at);
CREATE INDEX push_subscriptions_endpoint ON push_subscriptions(endpoint);

-- Keys the server makes once and keeps (the Web Push VAPID signing key).
CREATE TABLE server_keys (
    name       TEXT    PRIMARY KEY,
    value      TEXT    NOT NULL,
    created_at INTEGER NOT NULL
);

-- Reactions (F11) in direct chats: end-to-end encrypted like texts. The
-- newest row per (message, sender) is the current one; a NULL ciphertext
-- means it was taken back.
CREATE TABLE reactions (
    id         INTEGER PRIMARY KEY,
    message_id INTEGER NOT NULL REFERENCES messages(id),
    sender_id  INTEGER NOT NULL REFERENCES users(id),
    ciphertext TEXT,
    format     INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX reactions_message ON reactions(message_id, sender_id, id);

-- The same for group chats, in plain text like the rest of a group.
CREATE TABLE group_reactions (
    id         INTEGER PRIMARY KEY,
    message_id INTEGER NOT NULL REFERENCES group_messages(id),
    user_id    INTEGER NOT NULL REFERENCES users(id),
    emoji      TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX group_reactions_message ON group_reactions(message_id, user_id, id);

-- Replies in group chats (direct-chat replies are inside the encryption).
ALTER TABLE group_messages ADD COLUMN reply_to INTEGER REFERENCES group_messages(id);
