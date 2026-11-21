ALTER TABLE message ADD COLUMN origin TEXT NOT NULL DEFAULT 'unknown';
CREATE TABLE human_authorization (
    id INTEGER PRIMARY KEY,
    session_id INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
    seq INTEGER NOT NULL,
    text TEXT NOT NULL
);
CREATE INDEX human_authorization_session ON human_authorization(session_id, seq);
