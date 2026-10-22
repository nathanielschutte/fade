-- Optional birthdays (F19), on profiles for friends to see. Append-only like
-- user_names: the newest row per person wins, and a row with no month clears
-- it. The year is optional.
CREATE TABLE user_birthdays (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    month      INTEGER CHECK (month BETWEEN 1 AND 12),
    day        INTEGER CHECK (day BETWEEN 1 AND 31),
    year       INTEGER,
    created_at INTEGER NOT NULL,
    CHECK ((month IS NULL) = (day IS NULL))
);
CREATE INDEX user_birthdays_user ON user_birthdays(user_id, id);
