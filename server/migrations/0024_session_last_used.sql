-- When each session was last used (to the hour), so the device cap ends the
-- session least recently used, not the oldest sign-in (a phone in daily use
-- was being signed out by sessions its browser had long forgotten), and
-- sessions in use keep renewing. Nullable: older rows count from created_at.
ALTER TABLE sessions ADD COLUMN last_used_at INTEGER;
