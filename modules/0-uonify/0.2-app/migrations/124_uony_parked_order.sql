-- D8 («Consultor google», 21-10-2026): a written message while the account's
-- current work runs may become its next order, parked until that work ends;
-- the queue then releases it. Still one active job per account that can run,
-- and at most one parked order beside it. Parked = available_at
-- '9999-12-31 00:00:00+00', the literal of PARKED_UNTIL (uony_queue_lifecycle;
-- a test checks they match). Idempotent; rows that would break the new
-- indexes stop it with a clear message instead of a bare unique violation.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM uony_conversation_jobs
               WHERE status = 'queued' AND available_at = '9999-12-31 00:00:00+00'::timestamptz
               GROUP BY user_id HAVING count(*) > 1) THEN
        RAISE EXCEPTION '124_uony_parked_order: hay cuentas con más de una orden aparcada; revisa uony_conversation_jobs antes de migrar';
    END IF;
    IF EXISTS (SELECT 1 FROM uony_conversation_jobs
               WHERE status IN ('queued','running') AND available_at <> '9999-12-31 00:00:00+00'::timestamptz
               GROUP BY user_id HAVING count(*) > 1) THEN
        RAISE EXCEPTION '124_uony_parked_order: hay cuentas con más de un trabajo activo; revisa uony_conversation_jobs antes de migrar';
    END IF;
END $$;
DROP INDEX IF EXISTS uony_conversation_one_active_per_user;
CREATE UNIQUE INDEX IF NOT EXISTS uony_conversation_one_active_per_user ON uony_conversation_jobs (user_id)
    WHERE status IN ('queued','running') AND available_at <> '9999-12-31 00:00:00+00'::timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS uony_conversation_one_parked_per_user ON uony_conversation_jobs (user_id)
    WHERE status = 'queued' AND available_at = '9999-12-31 00:00:00+00'::timestamptz;
