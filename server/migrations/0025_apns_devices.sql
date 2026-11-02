-- Notifications on iPhones (apns.rs): one row per app install that turned
-- them on, tied to the session that did it, as push_subscriptions are for
-- browsers. Signing out (or the session ending) stops them. Rows are marked
-- ended, never deleted.
CREATE TABLE apns_devices (
    id           INTEGER PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES users(id),
    session_hash TEXT    NOT NULL,
    -- The device token, lowercase hex, as Apple gives it to the app.
    token        TEXT    NOT NULL,
    -- 'production' (TestFlight, the App Store) or 'sandbox' (Xcode builds):
    -- which of Apple's servers knows this token.
    environment  TEXT    NOT NULL,
    created_at   INTEGER NOT NULL,
    ended_at     INTEGER,
    end_reason   TEXT CHECK (end_reason IN ('turned_off', 'replaced', 'signed_out', 'gone'))
);
CREATE INDEX apns_devices_user ON apns_devices(user_id, ended_at);
CREATE INDEX apns_devices_token ON apns_devices(token);
