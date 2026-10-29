-- Past usernames (usernames.rs; plan X30). Changing your username keeps the
-- old one here, reserved for you forever: it still leads to you, and nobody
-- else can take it. `until` is when it stopped being your username. Additive
-- only.
CREATE TABLE past_usernames (
    id       INTEGER PRIMARY KEY,
    user_id  INTEGER NOT NULL REFERENCES users(id),
    username TEXT    NOT NULL COLLATE NOCASE,
    until    INTEGER NOT NULL
);
CREATE UNIQUE INDEX past_usernames_name ON past_usernames(username);
CREATE INDEX past_usernames_user ON past_usernames(user_id, id);
