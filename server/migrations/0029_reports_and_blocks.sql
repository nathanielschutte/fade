-- Report and block (F28; docs/design/report-and-block.md): reports.rs,
-- blocks.rs. Additive only (CLAUDE.md, Rule 1): reports and their outcomes
-- are append-only; a block ends by setting `ended_at`. A person deleting
-- their own account (deletion.rs) is the one thing that removes these rows.

-- Something someone reported: a direct message sent to them, a group message
-- in their history, or a person. Never the content: what the server already
-- knows about it (whose, which, what kind, when).
CREATE TABLE reports (
    id            INTEGER PRIMARY KEY,
    reporter_id   INTEGER NOT NULL REFERENCES users(id),
    reported_id   INTEGER NOT NULL REFERENCES users(id),
    kind          TEXT    NOT NULL CHECK (kind IN ('message', 'group_message', 'person')),
    -- messages.id for `message`, group_messages.id for `group_message`.
    -- Not a foreign key: a deleted account's messages go before its reports.
    message_id    INTEGER,
    group_id      INTEGER REFERENCES groups(id),
    -- What kind of message it was ('text', 'pic', 'video'), and when it was sent.
    message_kind  TEXT,
    message_at    INTEGER,
    reason        TEXT    NOT NULL
                  CHECK (reason IN ('spam', 'harassment', 'nudity', 'violence', 'hate', 'other')),
    -- The reporter's own words, for Admins (checked like other stored text).
    note          TEXT,
    created_at    INTEGER NOT NULL
);
CREATE INDEX reports_time ON reports(created_at);
CREATE INDEX reports_reported ON reports(reported_id, created_at);
CREATE INDEX reports_reporter ON reports(reporter_id, created_at);
-- One report per message per person: a retry finds the first.
CREATE UNIQUE INDEX reports_once ON reports(reporter_id, kind, message_id) WHERE message_id IS NOT NULL;

-- What an Admin did about a report: one outcome each, never changed.
CREATE TABLE report_outcomes (
    id          INTEGER PRIMARY KEY,
    report_id   INTEGER NOT NULL REFERENCES reports(id),
    action      TEXT    NOT NULL CHECK (action IN ('dismissed', 'warned', 'suspended', 'blocked')),
    admin_id    INTEGER NOT NULL REFERENCES users(id),
    -- The Admin's words to the reported person (warned, suspended, blocked).
    notice      TEXT,
    -- A note only Admins see (dismissed).
    note        TEXT,
    -- When a suspension ends.
    until       INTEGER,
    -- The Team Napsack message that told them (team.rs), if it went.
    message_id  INTEGER,
    created_at  INTEGER NOT NULL
);
CREATE UNIQUE INDEX report_outcomes_once ON report_outcomes(report_id);

-- Who has blocked whom. Unblocking sets `ended_at`; blocking again adds a row.
CREATE TABLE blocks (
    id          INTEGER PRIMARY KEY,
    blocker_id  INTEGER NOT NULL REFERENCES users(id),
    blocked_id  INTEGER NOT NULL REFERENCES users(id),
    created_at  INTEGER NOT NULL,
    ended_at    INTEGER
);
CREATE UNIQUE INDEX blocks_current ON blocks(blocker_id, blocked_id) WHERE ended_at IS NULL;
CREATE INDEX blocks_blocked ON blocks(blocked_id, blocker_id) WHERE ended_at IS NULL;
CREATE INDEX blocks_made ON blocks(blocker_id, created_at);

-- A turned-off account can end by itself (a suspension), and can say why to
-- the person (`notice`, shown when they sign in); `reason` stays Admins-only.
ALTER TABLE deactivations ADD COLUMN until INTEGER;
ALTER TABLE deactivations ADD COLUMN notice TEXT;
CREATE INDEX deactivations_until ON deactivations(until) WHERE until IS NOT NULL AND reactivated_at IS NULL;

-- Why a friendship ended, when it wasn't plain unfriending ('blocked').
ALTER TABLE friendships ADD COLUMN ended_reason TEXT;
