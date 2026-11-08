-- Hallazgo B («Consultor google», 21-10-2026; ESPEC-F1 §6.2 brought forward
-- for the written agent): every model attempt is recorded before it is sent,
-- with its logical call (ordinal) and its number. In text, one retry per call:
-- up to 3 retries and 6 attempts per job. A 429 attempt is a rejection and
-- consumes nothing; any other failed attempt is uncertain consumption.
-- Idempotent; rows that would break the new limits stop it with a clear message.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM uony_conversation_jobs WHERE provider_attempt_count > 6) THEN
        RAISE EXCEPTION '125_uony_provider_attempts: hay trabajos con más de 6 intentos; revisa uony_conversation_jobs antes de migrar';
    END IF;
END $$;
CREATE TABLE IF NOT EXISTS uony_provider_attempts (
    user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    ordinal smallint NOT NULL CHECK (ordinal BETWEEN 1 AND 3),
    attempt smallint NOT NULL CHECK (attempt IN (1,2)),
    model text NOT NULL CHECK (model ~ '^[a-z0-9.-]{1,64}$'),
    location text NOT NULL CHECK (location ~ '^[a-z0-9-]{1,32}$'),
    thinking_level text NOT NULL CHECK (thinking_level IN ('LOW','MEDIUM','HIGH')),
    timeout_ms integer NOT NULL CHECK (timeout_ms BETWEEN 1000 AND 60000),
    outcome text NOT NULL DEFAULT 'started'
        CHECK (outcome IN ('started','completed','failed')),
    error_kind text CHECK (error_kind ~ '^[a-z0-9_]{1,40}$'),
    http_code smallint CHECK (http_code BETWEEN 100 AND 599),
    elapsed_ms integer CHECK (elapsed_ms >= 0),
    usage jsonb NOT NULL DEFAULT '{}',
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    PRIMARY KEY (user_id, request_id, ordinal, attempt),
    FOREIGN KEY (user_id, request_id) REFERENCES uony_requests(user_id, request_id) ON DELETE CASCADE,
    CHECK ((outcome = 'started') = (finished_at IS NULL))
);
CREATE INDEX IF NOT EXISTS uony_provider_attempts_started ON uony_provider_attempts(started_at);
DROP TRIGGER IF EXISTS account_write_allowed ON uony_provider_attempts;
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_provider_attempts
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
ALTER TABLE uony_conversation_jobs ADD COLUMN IF NOT EXISTS provider_retry_count smallint NOT NULL DEFAULT 0;
ALTER TABLE uony_conversation_jobs DROP CONSTRAINT IF EXISTS uony_conversation_jobs_provider_retry_count_check;
ALTER TABLE uony_conversation_jobs ADD CONSTRAINT uony_conversation_jobs_provider_retry_count_check
    CHECK (provider_retry_count BETWEEN 0 AND 3);
ALTER TABLE uony_conversation_jobs DROP CONSTRAINT IF EXISTS uony_conversation_jobs_provider_attempt_count_check;
ALTER TABLE uony_conversation_jobs ADD CONSTRAINT uony_conversation_jobs_provider_attempt_count_check
    CHECK (provider_attempt_count >= 0 AND provider_attempt_count <= 6);
