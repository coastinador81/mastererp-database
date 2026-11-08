-- Durable, content-free progress for the existing conversation job.
-- A sequence advances on every lifecycle transition, including failures and
-- pre-provider requeue, so repeated GETs can be reconciled by requestId/seq.
ALTER TABLE uony_conversation_jobs
    ADD COLUMN progress_stage text NOT NULL DEFAULT 'queued'
        CHECK (progress_stage IN ('queued','preparing','consulting_google','checking_result','saved')),
    ADD COLUMN progress_seq bigint NOT NULL DEFAULT 1 CHECK (progress_seq>=1),
    ADD COLUMN first_claimed_at timestamptz,
    ADD COLUMN last_claimed_at timestamptz,
    ADD COLUMN provider_returned_at timestamptz,
    ADD COLUMN finished_at timestamptz;

-- Existing jobs cannot provide reliable stage timings. Preserve their outcome
-- without manufacturing timestamps or interpreting an uncertain call as saved.
UPDATE uony_conversation_jobs SET
    progress_stage=CASE
        WHEN status='success' THEN 'saved'
        WHEN provider_started_at IS NOT NULL THEN 'consulting_google'
        WHEN claim_count>0 THEN 'preparing'
        ELSE 'queued' END,
    progress_seq=CASE
        WHEN status='success' THEN 5
        WHEN provider_started_at IS NOT NULL THEN 3
        WHEN claim_count>0 THEN 2
        ELSE 1 END;
