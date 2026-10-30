-- PowerXtreme (docs/implementation/roles.md): a step above PowerUser, granted
-- and taken away by Admins only, to people who are PowerUsers now. Its own
-- table, since user_roles allows only 'power' and migrations never rewrite a
-- table. The same append-only marks: taking it away sets revoked_at, granting
-- again adds a row (Rule 1). `role` has no CHECK, so later steps can join it.
CREATE TABLE user_role_upgrades (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    role       TEXT    NOT NULL,
    granted_by INTEGER NOT NULL REFERENCES users(id),
    granted_at INTEGER NOT NULL,
    revoked_by INTEGER REFERENCES users(id),
    revoked_at INTEGER
);
CREATE UNIQUE INDEX user_role_upgrades_current ON user_role_upgrades(user_id, role) WHERE revoked_at IS NULL;
