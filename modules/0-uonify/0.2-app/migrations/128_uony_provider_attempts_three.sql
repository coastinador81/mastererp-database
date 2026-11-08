-- Lote 6 («Consultor google», 21-10-2026, option A): a 429 burst outlasted
-- one retry in B2 n.º 4 and C2, so a call may take a third attempt, only after
-- a 429 (enforced by uony_queue_attempts.stream_retry). The job's caps do not
-- change: 3 retries and 6 attempts per job. Lote 5 writes only 1 and 2, so it
-- still runs on a database with this migration. Idempotent; NOT VALID first,
-- then VALIDATE, so the check scans the table without blocking its writers.
ALTER TABLE uony_provider_attempts DROP CONSTRAINT IF EXISTS uony_provider_attempts_attempt_check;
ALTER TABLE uony_provider_attempts ADD CONSTRAINT uony_provider_attempts_attempt_check
    CHECK (attempt BETWEEN 1 AND 3) NOT VALID;
ALTER TABLE uony_provider_attempts VALIDATE CONSTRAINT uony_provider_attempts_attempt_check;
