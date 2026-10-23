-- Roles (docs/roles.md). Admins come from settings, never the database; this
-- holds PowerUser grants. Taking the role away marks revoked_at, and granting
-- again adds a row, so the history of who granted what is kept (Rule 1).
CREATE TABLE user_roles (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    role       TEXT    NOT NULL CHECK (role IN ('power')),
    granted_by INTEGER NOT NULL REFERENCES users(id),
    granted_at INTEGER NOT NULL,
    revoked_by INTEGER REFERENCES users(id),
    revoked_at INTEGER
);
CREATE UNIQUE INDEX user_roles_current ON user_roles(user_id, role) WHERE revoked_at IS NULL;
