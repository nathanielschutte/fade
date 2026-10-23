-- View-once pics now count as opened when the app confirms it showed them,
-- not when the server sends them, so a dropped connection or a too-quick tap
-- can't lose a pic. These record the first fetch, so a pic that was fetched
-- but never confirmed (an older app, an abandoned open) still counts as
-- opened a few minutes later.
ALTER TABLE messages ADD COLUMN snap_fetched_at INTEGER;

CREATE TABLE group_pic_fetches (
    pic_id     INTEGER NOT NULL REFERENCES group_pics(id),
    user_id    INTEGER NOT NULL REFERENCES users(id),
    fetched_at INTEGER NOT NULL,
    PRIMARY KEY (pic_id, user_id)
);

-- A random id the sending app picks for each direct text or pic, so a send
-- retried after a dropped connection returns the message already stored
-- instead of storing it twice. (Format 3 group messages already have one.)
ALTER TABLE messages ADD COLUMN client_id TEXT;
CREATE UNIQUE INDEX messages_client ON messages(sender_id, client_id) WHERE client_id IS NOT NULL;
