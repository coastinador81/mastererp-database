-- Only tentative, bounded text from the current fenced Gemini turn is stored.
-- It is never a committed assistant answer and is erased on terminal state.
ALTER TABLE uony_conversation_jobs
    ADD COLUMN provisional_text text NOT NULL DEFAULT ''
        CHECK (char_length(provisional_text) <= 16000),
    ADD COLUMN provisional_seq bigint NOT NULL DEFAULT 0 CHECK (provisional_seq >= 0),
    ADD COLUMN provider_attempt_count integer NOT NULL DEFAULT 0
        CHECK (provider_attempt_count BETWEEN 0 AND 3),
    ADD COLUMN provider_completed_count integer NOT NULL DEFAULT 0
        CHECK (provider_completed_count BETWEEN 0 AND provider_attempt_count);

-- Conservative historical backfill: an already-started request is never
-- treated as a free, unattempted call merely because it predates this ledger.
UPDATE uony_conversation_jobs SET
    provider_attempt_count=CASE WHEN provider_started_at IS NOT NULL THEN 1 ELSE 0 END,
    provider_completed_count=CASE WHEN status='success' THEN 1 ELSE 0 END;
