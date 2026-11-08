-- Admission budget survives erasure of a conversation's transcripts and usage.
-- This opaque per-account receipt contains no thread, audio, text or token data.
CREATE TABLE uony_live_pilot_admissions (
 user_id uuid NOT NULL REFERENCES users(id),
 session_id uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (user_id,session_id)
);
-- Preserve the budget of sessions started before this migration. A deleted
-- conversation's usage may already be gone; pilots must be disabled for the
-- migration so that no new admission can race this backfill.
INSERT INTO uony_live_pilot_admissions(user_id,session_id,created_at)
 SELECT user_id,session_id,created_at FROM uony_live_usage
 ON CONFLICT DO NOTHING;

CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_live_pilot_admissions
 FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
