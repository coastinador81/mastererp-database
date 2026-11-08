-- Immutable admission receipts and fenced step attempts for the existing
-- creative_execution_jobs/steps backlog. Dispatch stays disabled by the 088
-- CHECK (dispatch_authorized = false); no route or worker consumes these rows.
CREATE TABLE creative_execution_admissions (
    user_id uuid NOT NULL,
    job_id uuid NOT NULL,
    id uuid NOT NULL,
    admission_sha256 text NOT NULL
        CHECK (admission_sha256 ~ '^[0-9a-f]{64}$'),
    input_claim_set_sha256 text NOT NULL
        CHECK (input_claim_set_sha256 ~ '^[0-9a-f]{64}$'),
    input_claims jsonb NOT NULL CHECK (jsonb_typeof(input_claims) = 'array'),
    execution_graph_sha256 text NOT NULL
        CHECK (execution_graph_sha256 ~ '^[0-9a-f]{64}$'),
    quote_sha256 text NOT NULL CHECK (quote_sha256 ~ '^[0-9a-f]{64}$'),
    binding_sha256 text NOT NULL CHECK (binding_sha256 ~ '^[0-9a-f]{64}$'),
    costs_snapshot_sha256 text NOT NULL
        CHECK (costs_snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    expires_at timestamptz NOT NULL,
    admitted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,job_id),
    UNIQUE (user_id,id),
    UNIQUE (user_id,job_id,id,admission_sha256),
    FOREIGN KEY (user_id,job_id)
        REFERENCES creative_execution_jobs(user_id,id) ON DELETE CASCADE,
    CHECK (admitted_at < expires_at)
);

CREATE TABLE creative_execution_attempts (
    user_id uuid NOT NULL,
    job_id uuid NOT NULL,
    step_id uuid NOT NULL,
    id uuid NOT NULL,
    attempt_no integer NOT NULL CHECK (attempt_no > 0),
    admission_id uuid NOT NULL,
    admission_sha256 text NOT NULL
        CHECK (admission_sha256 ~ '^[0-9a-f]{64}$'),
    claim_set_sha256 text NOT NULL
        CHECK (claim_set_sha256 ~ '^[0-9a-f]{64}$'),
    claim_snapshot jsonb NOT NULL CHECK (jsonb_typeof(claim_snapshot) = 'array'),
    status text NOT NULL CHECK (status IN
        ('running','succeeded','failed','unknown','cancelled')),
    claim_lease_token uuid NOT NULL,
    lease_token uuid,
    lease_owner text,
    lease_until timestamptz,
    fence_epoch bigint NOT NULL CHECK (fence_epoch > 0),
    provider_started_at timestamptz,
    provider_returned_at timestamptz,
    provider_receipt jsonb,
    result_receipt jsonb,
    result_sha256 text CHECK (result_sha256 ~ '^[0-9a-f]{64}$'),
    usage jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(usage) = 'object'),
    error_code text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    PRIMARY KEY (user_id,job_id,step_id,attempt_no),
    UNIQUE (user_id,id),
    UNIQUE (user_id,job_id,step_id,attempt_no,id,claim_lease_token,fence_epoch,
            admission_id,admission_sha256,claim_set_sha256),
    FOREIGN KEY (user_id,job_id)
        REFERENCES creative_execution_admissions(user_id,job_id) ON DELETE CASCADE,
    FOREIGN KEY (user_id,job_id,step_id)
        REFERENCES creative_execution_steps(user_id,job_id,step_id)
        ON DELETE CASCADE,
    FOREIGN KEY (user_id,job_id,admission_id,admission_sha256)
        REFERENCES creative_execution_admissions
            (user_id,job_id,id,admission_sha256),
    CHECK ((status = 'running') = (lease_token IS NOT NULL)),
    CHECK ((status = 'running') = (lease_owner IS NOT NULL)),
    CHECK ((status = 'running') = (lease_until IS NOT NULL)),
    CHECK ((status IN ('succeeded','failed','unknown','cancelled'))
           = (finished_at IS NOT NULL)),
    CHECK (provider_returned_at IS NULL OR provider_started_at IS NOT NULL),
    CHECK (provider_receipt IS NULL OR provider_returned_at IS NOT NULL),
    CHECK (result_receipt IS NULL OR jsonb_typeof(result_receipt) = 'object'),
    CHECK ((result_receipt IS NULL) = (result_sha256 IS NULL)),
    CHECK (provider_receipt IS NULL OR provider_receipt = result_receipt)
);

CREATE UNIQUE INDEX creative_execution_one_running_attempt
    ON creative_execution_attempts(user_id,job_id,step_id)
    WHERE status = 'running';
CREATE INDEX creative_execution_attempts_expired
    ON creative_execution_attempts(lease_until,user_id,job_id,step_id)
    WHERE status = 'running';

CREATE FUNCTION creative_execution_admission_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'creative execution admission receipts are immutable';
END;
$$;
CREATE TRIGGER creative_execution_admission_immutable
    BEFORE UPDATE ON creative_execution_admissions
    FOR EACH ROW EXECUTE FUNCTION creative_execution_admission_immutable();

CREATE FUNCTION creative_execution_attempt_identity_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (OLD.user_id,OLD.job_id,OLD.step_id,OLD.id,OLD.attempt_no,
        OLD.admission_id,OLD.admission_sha256,OLD.claim_set_sha256,
        OLD.claim_snapshot,OLD.claim_lease_token,OLD.fence_epoch,OLD.created_at)
       IS DISTINCT FROM
       (NEW.user_id,NEW.job_id,NEW.step_id,NEW.id,NEW.attempt_no,
        NEW.admission_id,NEW.admission_sha256,NEW.claim_set_sha256,
        NEW.claim_snapshot,NEW.claim_lease_token,NEW.fence_epoch,NEW.created_at)
    THEN
        RAISE EXCEPTION 'creative execution attempt identity is immutable';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER creative_execution_attempt_identity_immutable
    BEFORE UPDATE ON creative_execution_attempts
    FOR EACH ROW EXECUTE FUNCTION creative_execution_attempt_identity_immutable();

CREATE FUNCTION creative_execution_attempt_monotonic()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status <> 'running' AND OLD IS DISTINCT FROM NEW THEN
        RAISE EXCEPTION 'terminal creative execution attempts are immutable';
    END IF;
    IF (OLD.provider_started_at IS NOT NULL
            AND OLD.provider_started_at IS DISTINCT FROM NEW.provider_started_at)
        OR (OLD.provider_returned_at IS NOT NULL
            AND OLD.provider_returned_at IS DISTINCT FROM NEW.provider_returned_at)
        OR (OLD.provider_receipt IS NOT NULL
            AND OLD.provider_receipt IS DISTINCT FROM NEW.provider_receipt)
        OR (OLD.result_receipt IS NOT NULL
            AND OLD.result_receipt IS DISTINCT FROM NEW.result_receipt)
        OR (OLD.result_sha256 IS NOT NULL
            AND OLD.result_sha256 IS DISTINCT FROM NEW.result_sha256)
    THEN
        RAISE EXCEPTION 'creative execution checkpoints are append-only';
    END IF;
    IF NEW.status = 'running'
       AND (OLD.lease_token,OLD.lease_owner)
           IS DISTINCT FROM (NEW.lease_token,NEW.lease_owner)
    THEN
        RAISE EXCEPTION 'creative execution lease identity is immutable';
    END IF;
    IF NEW.status = 'succeeded'
       AND (NEW.result_receipt IS NULL OR NEW.result_sha256 IS NULL)
    THEN
        RAISE EXCEPTION 'successful creative attempts require a durable result';
    END IF;
    IF NEW.status = 'unknown'
       AND (NEW.provider_started_at IS NULL
            OR NEW.provider_returned_at IS NOT NULL)
    THEN
        RAISE EXCEPTION 'unknown creative attempts require an uncertain provider effect';
    END IF;
    IF NEW.provider_returned_at IS NOT NULL
       AND (NEW.provider_receipt IS NULL OR NEW.result_receipt IS NULL
            OR NEW.result_sha256 IS NULL)
    THEN
        RAISE EXCEPTION 'provider return requires a durable result receipt';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER creative_execution_attempt_monotonic
    BEFORE UPDATE ON creative_execution_attempts
    FOR EACH ROW EXECUTE FUNCTION creative_execution_attempt_monotonic();

CREATE TRIGGER account_write_allowed
    BEFORE INSERT ON creative_execution_admissions
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT OR UPDATE ON creative_execution_attempts
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
