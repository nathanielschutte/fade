-- Accounts their owners deleted (deletion.rs; docs/design/account-deletion.md).
-- Everything of theirs is gone; the users row stays hollow (its id only), and
-- this says when. For 30 days the username is held as a keyed hash, so nobody
-- can take it and pose as the person; then the hash is cleared.
CREATE TABLE deleted_accounts (
    user_id       INTEGER PRIMARY KEY REFERENCES users(id),
    deleted_at    INTEGER NOT NULL,
    username_hmac TEXT,
    held_until    INTEGER
);
CREATE INDEX deleted_accounts_hold ON deleted_accounts(username_hmac);
