-- System → Users (admin_users.rs) and announcements (announcements.rs).
-- Additive only (CLAUDE.md, Rule 1): nothing here is ever deleted or updated
-- except the "ended" columns, which are only ever set once.

-- Turned-off accounts. An Admin turning one off adds a row; turning it back
-- on marks that row ended. The account and everything in it stay as they were.
CREATE TABLE deactivations (
    id              INTEGER PRIMARY KEY,
    user_id         INTEGER NOT NULL REFERENCES users(id),
    -- Why, in the Admin's words (shown to Admins only; validated like other stored text).
    reason          TEXT,
    deactivated_by  INTEGER NOT NULL REFERENCES users(id),
    deactivated_at  INTEGER NOT NULL,
    reactivated_by  INTEGER REFERENCES users(id),
    reactivated_at  INTEGER
);
CREATE UNIQUE INDEX deactivations_current ON deactivations(user_id) WHERE reactivated_at IS NULL;

-- Every action an Admin takes on someone's account, append-only: who, what,
-- to whom, when. `detail` is a little JSON (never a secret, code, or content).
CREATE TABLE admin_actions (
    id              INTEGER PRIMARY KEY,
    admin_id        INTEGER NOT NULL REFERENCES users(id),
    action          TEXT NOT NULL,
    target_user_id  INTEGER REFERENCES users(id),
    detail          TEXT,
    created_at      INTEGER NOT NULL
);
CREATE INDEX admin_actions_target ON admin_actions(target_user_id, created_at);
CREATE INDEX admin_actions_time ON admin_actions(created_at);

-- A short message from the Admins, shown to everyone signed in until it ends
-- or is withdrawn. One at a time: posting a new one withdraws the last.
CREATE TABLE announcements (
    id            INTEGER PRIMARY KEY,
    body          TEXT NOT NULL,
    created_by    INTEGER NOT NULL REFERENCES users(id),
    created_at    INTEGER NOT NULL,
    ends_at       INTEGER NOT NULL,
    withdrawn_by  INTEGER REFERENCES users(id),
    withdrawn_at  INTEGER
);
