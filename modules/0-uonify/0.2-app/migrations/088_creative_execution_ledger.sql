-- Additive ledger for one approved composite multimedia execution. The legacy
-- 084 single-request ledger remains unchanged. This migration stores exact
-- receipts and a held graph; it does not admit or dispatch provider work.
CREATE TABLE creative_execution_quotes (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    issue_request_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    thread_id text NOT NULL,
    uonify_project_id uuid,
    google_subject text NOT NULL,
    google_project_id text NOT NULL,
    plan_revision integer NOT NULL CHECK (plan_revision > 0),
    source_plan_sha256 text NOT NULL CHECK (source_plan_sha256 ~ '^[0-9a-f]{64}$'),
    execution_snapshot_sha256 text NOT NULL CHECK (execution_snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    edit_recipe_sha256 text NOT NULL CHECK (edit_recipe_sha256 ~ '^[0-9a-f]{64}$'),
    input_manifest_sha256 text NOT NULL CHECK (input_manifest_sha256 ~ '^[0-9a-f]{64}$'),
    request_group_sha256 text NOT NULL CHECK (request_group_sha256 ~ '^[0-9a-f]{64}$'),
    limits_sha256 text NOT NULL CHECK (limits_sha256 ~ '^[0-9a-f]{64}$'),
    binding_sha256 text NOT NULL CHECK (binding_sha256 ~ '^[0-9a-f]{64}$'),
    costs_snapshot_sha256 text NOT NULL CHECK (costs_snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    quote_sha256 text NOT NULL CHECK (quote_sha256 ~ '^[0-9a-f]{64}$'),
    source_plan_snapshot jsonb NOT NULL CHECK (jsonb_typeof(source_plan_snapshot) = 'object'),
    execution_snapshot jsonb NOT NULL CHECK (jsonb_typeof(execution_snapshot) = 'object'),
    edit_recipe jsonb NOT NULL CHECK (jsonb_typeof(edit_recipe) = 'object'),
    input_manifest jsonb NOT NULL CHECK (jsonb_typeof(input_manifest) = 'array'),
    limits_snapshot jsonb NOT NULL CHECK (jsonb_typeof(limits_snapshot) = 'object'),
    quote_snapshot jsonb NOT NULL CHECK (jsonb_typeof(quote_snapshot) = 'object'),
    max_total_usd numeric(12,2) NOT NULL CHECK (max_total_usd > 0),
    currency text NOT NULL CHECK (currency = 'USD'),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL CHECK (expires_at > created_at),
    UNIQUE (user_id,issue_request_id),
    UNIQUE (user_id,id),
    FOREIGN KEY (user_id,plan_id) REFERENCES uony_creative_plans(user_id,id) ON DELETE CASCADE,
    FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id),
    FOREIGN KEY (user_id,uonify_project_id) REFERENCES uony_projects(user_id,id)
);

CREATE TABLE creative_execution_approvals (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    quote_id uuid NOT NULL,
    request_id uuid NOT NULL,
    actor_id uuid NOT NULL,
    quote_sha256 text NOT NULL CHECK (quote_sha256 ~ '^[0-9a-f]{64}$'),
    binding_sha256 text NOT NULL CHECK (binding_sha256 ~ '^[0-9a-f]{64}$'),
    costs_snapshot_sha256 text NOT NULL CHECK (costs_snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    max_total_usd numeric(12,2) NOT NULL CHECK (max_total_usd > 0),
    approved_at timestamptz NOT NULL,
    UNIQUE (user_id,quote_id),
    UNIQUE (user_id,request_id),
    UNIQUE (user_id,id),
    FOREIGN KEY (user_id,quote_id) REFERENCES creative_execution_quotes(user_id,id) ON DELETE CASCADE,
    CHECK (actor_id = user_id)
);

CREATE TABLE creative_execution_jobs (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    approval_id uuid NOT NULL,
    request_id uuid NOT NULL,
    thread_id text NOT NULL,
    execution_graph_sha256 text NOT NULL CHECK (execution_graph_sha256 ~ '^[0-9a-f]{64}$'),
    graph_snapshot jsonb NOT NULL CHECK (jsonb_typeof(graph_snapshot) = 'object'),
    status text NOT NULL CHECK (status IN
        ('held','queued','running','succeeded','failed','unknown','cancelled')),
    dispatch_authorized boolean NOT NULL DEFAULT false CHECK (dispatch_authorized = false),
    lease_token uuid,
    lease_owner text,
    lease_until timestamptz,
    claim_count integer NOT NULL DEFAULT 0 CHECK (claim_count >= 0),
    available_at timestamptz NOT NULL DEFAULT now(),
    progress jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(progress) = 'object'),
    error_code text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    UNIQUE (user_id,approval_id),
    UNIQUE (user_id,request_id),
    UNIQUE (user_id,id),
    FOREIGN KEY (user_id,approval_id) REFERENCES creative_execution_approvals(user_id,id) ON DELETE CASCADE,
    FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id),
    CHECK ((status = 'running') = (lease_token IS NOT NULL)),
    CHECK ((status = 'running') = (lease_owner IS NOT NULL)),
    CHECK ((status = 'running') = (lease_until IS NOT NULL)),
    CHECK ((status IN ('succeeded','failed','unknown','cancelled')) = (finished_at IS NOT NULL))
);

CREATE TABLE creative_execution_steps (
    user_id uuid NOT NULL,
    job_id uuid NOT NULL,
    step_id uuid NOT NULL,
    ordinal integer NOT NULL CHECK (ordinal > 0),
    kind text NOT NULL CHECK (kind IN
        ('google_generation','storage_adopt','craft','review')),
    unit_id text NOT NULL,
    request_operation_id uuid,
    authority_sha256 text NOT NULL CHECK (authority_sha256 ~ '^[0-9a-f]{64}$'),
    depends_on jsonb NOT NULL CHECK (jsonb_typeof(depends_on) = 'array'),
    provider_call boolean NOT NULL,
    replay_after_start boolean NOT NULL DEFAULT false CHECK (replay_after_start = false),
    status text NOT NULL CHECK (status IN
        ('held','queued','running','succeeded','failed','unknown','cancelled')),
    lease_token uuid,
    lease_owner text,
    lease_until timestamptz,
    claim_count integer NOT NULL DEFAULT 0 CHECK (claim_count >= 0),
    provider_started_at timestamptz,
    provider_returned_at timestamptz,
    provider_receipt jsonb,
    progress jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(progress) = 'object'),
    error_code text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    PRIMARY KEY (user_id,job_id,step_id),
    UNIQUE (user_id,job_id,ordinal),
    FOREIGN KEY (user_id,job_id) REFERENCES creative_execution_jobs(user_id,id) ON DELETE CASCADE,
    CHECK ((status = 'running') = (lease_token IS NOT NULL)),
    CHECK ((status = 'running') = (lease_owner IS NOT NULL)),
    CHECK ((status = 'running') = (lease_until IS NOT NULL)),
    CHECK ((status IN ('succeeded','failed','unknown','cancelled')) = (finished_at IS NOT NULL)),
    CHECK (provider_returned_at IS NULL OR provider_started_at IS NOT NULL),
    CHECK (provider_receipt IS NULL OR provider_returned_at IS NOT NULL)
);

CREATE INDEX creative_execution_quotes_plan
    ON creative_execution_quotes(user_id,plan_id,created_at DESC);
CREATE INDEX creative_execution_jobs_ready
    ON creative_execution_jobs(status,available_at,created_at,user_id,id)
    WHERE status = 'queued' AND dispatch_authorized;
CREATE INDEX creative_execution_steps_ready
    ON creative_execution_steps(status,created_at,user_id,job_id,ordinal)
    WHERE status = 'queued';
CREATE INDEX creative_execution_steps_expired
    ON creative_execution_steps
    ((coalesce(lease_until,'-infinity'::timestamptz)),user_id,job_id,ordinal)
    WHERE status = 'running';

CREATE FUNCTION creative_execution_receipt_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'creative execution quote and approval receipts are immutable';
END;
$$;
CREATE TRIGGER creative_execution_quote_immutable
    BEFORE UPDATE ON creative_execution_quotes
    FOR EACH ROW EXECUTE FUNCTION creative_execution_receipt_immutable();
CREATE TRIGGER creative_execution_approval_immutable
    BEFORE UPDATE ON creative_execution_approvals
    FOR EACH ROW EXECUTE FUNCTION creative_execution_receipt_immutable();

CREATE FUNCTION creative_execution_job_identity_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (OLD.user_id,OLD.approval_id,OLD.request_id,OLD.thread_id,
        OLD.execution_graph_sha256,OLD.graph_snapshot)
       IS DISTINCT FROM
       (NEW.user_id,NEW.approval_id,NEW.request_id,NEW.thread_id,
        NEW.execution_graph_sha256,NEW.graph_snapshot) THEN
        RAISE EXCEPTION 'creative execution job identity is immutable';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER creative_execution_job_identity_immutable
    BEFORE UPDATE ON creative_execution_jobs
    FOR EACH ROW EXECUTE FUNCTION creative_execution_job_identity_immutable();

CREATE FUNCTION creative_execution_step_identity_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (OLD.user_id,OLD.job_id,OLD.step_id,OLD.ordinal,OLD.kind,OLD.unit_id,
        OLD.request_operation_id,OLD.authority_sha256,OLD.depends_on,
        OLD.provider_call,OLD.replay_after_start)
       IS DISTINCT FROM
       (NEW.user_id,NEW.job_id,NEW.step_id,NEW.ordinal,NEW.kind,NEW.unit_id,
        NEW.request_operation_id,NEW.authority_sha256,NEW.depends_on,
        NEW.provider_call,NEW.replay_after_start) THEN
        RAISE EXCEPTION 'creative execution step identity is immutable';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER creative_execution_step_identity_immutable
    BEFORE UPDATE ON creative_execution_steps
    FOR EACH ROW EXECUTE FUNCTION creative_execution_step_identity_immutable();

CREATE TRIGGER account_write_allowed BEFORE INSERT ON creative_execution_quotes
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed BEFORE INSERT ON creative_execution_approvals
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON creative_execution_jobs
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON creative_execution_steps
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
