-- For the admin panel's "active" counts. Updated at most once a minute per user.
ALTER TABLE users ADD COLUMN last_seen_at INTEGER;
