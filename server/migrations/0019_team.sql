-- Team Napsack (team.rs) and its scheduled messages (occasions.rs;
-- docs/implementation/team-napsack.md). Additive only.

-- Accounts the server itself speaks for. They never sign in; their key pair
-- lives in server_keys. Today there's one: Team Napsack ('team').
CREATE TABLE system_accounts (
    user_id     INTEGER PRIMARY KEY REFERENCES users(id),
    kind        TEXT NOT NULL UNIQUE,
    created_at  INTEGER NOT NULL
);

-- One row per scheduled message sent: which occasion, which occurrence of
-- it (a date), and to whom. The unique index is what makes each go out
-- exactly once, across restarts.
CREATE TABLE occasion_sends (
    id          INTEGER PRIMARY KEY,
    occasion    TEXT NOT NULL,
    occurrence  TEXT NOT NULL,
    user_id     INTEGER NOT NULL REFERENCES users(id),
    message_id  INTEGER REFERENCES messages(id),
    sent_at     INTEGER NOT NULL
);
CREATE UNIQUE INDEX occasion_sends_once ON occasion_sends(occasion, occurrence, user_id);
