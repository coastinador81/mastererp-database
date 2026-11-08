-- Durable handoff from execution recovery to in-memory runtime cleanup.
-- The table does not activate a worker; it makes cleanup retryable once one
-- exists, including after an uncertain recovery commit.
CREATE TABLE creative_runtime_reconciliation_outbox (
    user_id uuid NOT NULL,
    attempt_id uuid NOT NULL,
    job_id uuid NOT NULL,
    step_id uuid NOT NULL,
    attempt_no integer NOT NULL CHECK (attempt_no > 0),
    claim_lease_token uuid NOT NULL,
    fence_epoch bigint NOT NULL CHECK (fence_epoch > 0),
    admission_sha256 text NOT NULL
        CHECK (admission_sha256 ~ '^[0-9a-f]{64}$'),
    claim_set_sha256 text NOT NULL
        CHECK (claim_set_sha256 ~ '^[0-9a-f]{64}$'),
    kind text NOT NULL CHECK (kind IN
        ('google_generation','storage_adopt','craft','candidate_adopt','review')),
    provider_call boolean NOT NULL,
    terminal_status text NOT NULL CHECK (terminal_status IN
        ('succeeded','failed','unknown','cancelled')),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','running','done','dead')),
    lease_token uuid,
    lease_until timestamptz,
    attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    last_error text,
    available_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    PRIMARY KEY (user_id,attempt_id),
    FOREIGN KEY (user_id,attempt_id)
        REFERENCES creative_execution_attempts(user_id,id),
    CHECK ((status='running') = (lease_token IS NOT NULL)),
    CHECK ((status='running') = (lease_until IS NOT NULL)),
    CHECK ((status='done') = (completed_at IS NOT NULL))
);

CREATE INDEX creative_runtime_reconciliation_pending
    ON creative_runtime_reconciliation_outbox
       (status,available_at,lease_until,created_at)
    WHERE status IN ('pending','running');

CREATE FUNCTION creative_runtime_reconciliation_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (OLD.user_id,OLD.attempt_id,OLD.job_id,OLD.step_id,OLD.attempt_no,
        OLD.claim_lease_token,OLD.fence_epoch,OLD.admission_sha256,
        OLD.claim_set_sha256,OLD.kind,OLD.provider_call,OLD.terminal_status,
        OLD.created_at) IS DISTINCT FROM
       (NEW.user_id,NEW.attempt_id,NEW.job_id,NEW.step_id,NEW.attempt_no,
        NEW.claim_lease_token,NEW.fence_epoch,NEW.admission_sha256,
        NEW.claim_set_sha256,NEW.kind,NEW.provider_call,NEW.terminal_status,
        NEW.created_at) THEN
        RAISE EXCEPTION 'creative runtime reconciliation identity is immutable';
    END IF;
    IF OLD.status='done' AND OLD IS DISTINCT FROM NEW THEN
        RAISE EXCEPTION 'completed runtime reconciliation is immutable';
    END IF;
    IF OLD.status='dead' AND OLD IS DISTINCT FROM NEW THEN
        RAISE EXCEPTION 'dead runtime reconciliation is immutable';
    END IF;
    IF NEW.attempt_count < OLD.attempt_count THEN
        RAISE EXCEPTION 'runtime reconciliation attempts are monotonic';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER creative_runtime_reconciliation_guard
    BEFORE UPDATE ON creative_runtime_reconciliation_outbox
    FOR EACH ROW EXECUTE FUNCTION creative_runtime_reconciliation_guard();
