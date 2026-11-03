-- Indexes for what every app reads again and again (the chat list, a chat,
-- profiles, pic streaks, the iPhone badge), which had come to read the whole
-- messages table, or a whole chat's history, every time. Texts are kept
-- forever, so those reads only grew. Indexes only: nothing stored changes
-- (CLAUDE.md, Rule 1).
--
-- SQLite uses a partial index (one with a WHERE) only for a query whose
-- WHERE includes that condition, word for word. Plan tests beside the
-- queries (db::tests::assert_searches) check they use these.

-- What each person received from each person, and when, as messages_pair has
-- what they sent: profiles' counts and the first message between two people.
CREATE INDEX messages_recipient ON messages(recipient_id, sender_id, created_at);

-- Waiting for each person, by whom: unread texts and unopened pics. Small,
-- since texts leave it once read and pics once opened. The chat list's
-- unread counts, marking a chat read, and the iPhone badge read only this.
CREATE INDEX messages_waiting ON messages(recipient_id, sender_id, created_at)
    WHERE (kind = 'text' AND read_at IS NULL) OR (kind = 'snap' AND snap_state = 'pending');

-- Direct pics between two people, by when they were sent, and whether
-- they've been opened: pic streaks, and profiles' counts of pics.
CREATE INDEX messages_pics ON messages(sender_id, recipient_id, created_at, snap_state)
    WHERE kind = 'snap';

-- Unopened pics, by when they were sent: the sweep that expires them every
-- minute, and the disk cap checked on every pic sent.
CREATE INDEX messages_unopened_pics ON messages(created_at)
    WHERE kind = 'snap' AND snap_state = 'pending';
