-- Personal "add me" links (invites.rs; plan X25): one per person that keeps
-- working, any number of times, until they reset it. It's an invite row
-- like the others, marked personal. Additive only.
ALTER TABLE invites ADD COLUMN personal INTEGER NOT NULL DEFAULT 0;
CREATE INDEX invites_personal ON invites(created_by, personal, revoked_at);
