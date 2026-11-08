-- Closed foundation for an exact creative spend approval. No provider dispatch
-- or public quote issuer is added by this migration.
ALTER TABLE uony_creative_plans
    ADD COLUMN revision integer NOT NULL DEFAULT 1 CHECK (revision > 0);

CREATE TABLE creative_generation_quotes (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    issue_request_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    thread_id text NOT NULL,
    uonify_project_id uuid,
    google_subject text NOT NULL,
    google_project_id text NOT NULL,
    payer text NOT NULL CHECK (payer = 'customer_google_project'),
    plan_revision integer NOT NULL CHECK (plan_revision > 0),
    plan_sha256 text NOT NULL CHECK (plan_sha256 ~ '^[0-9a-f]{64}$'),
    plan_snapshot jsonb NOT NULL CHECK (jsonb_typeof(plan_snapshot) = 'object'),
    product_id uuid,
    product_revision integer,
    operation text NOT NULL CHECK (operation IN ('image','video','music','voiceover')),
    model text NOT NULL,
    endpoint text NOT NULL,
    request_sha256 text NOT NULL CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
    request_snapshot jsonb NOT NULL CHECK (jsonb_typeof(request_snapshot) = 'object'),
    input_manifest jsonb NOT NULL CHECK (jsonb_typeof(input_manifest) = 'array'),
    pricing_snapshot jsonb NOT NULL CHECK (jsonb_typeof(pricing_snapshot) = 'object'),
    max_total_usd numeric(12,2) NOT NULL CHECK (max_total_usd > 0),
    quote_sha256 text NOT NULL CHECK (quote_sha256 ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL CHECK (expires_at > created_at),
    UNIQUE (user_id, issue_request_id),
    UNIQUE (user_id, id),
    FOREIGN KEY (user_id, plan_id) REFERENCES uony_creative_plans(user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (user_id, thread_id) REFERENCES uony_threads(user_id, id),
    FOREIGN KEY (user_id, uonify_project_id) REFERENCES uony_projects(user_id, id),
    CHECK ((product_id IS NULL) = (product_revision IS NULL))
);

CREATE TABLE creative_generation_approvals (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    quote_id uuid NOT NULL,
    request_id uuid NOT NULL,
    actor_id uuid NOT NULL,
    quote_sha256 text NOT NULL CHECK (quote_sha256 ~ '^[0-9a-f]{64}$'),
    plan_revision integer NOT NULL CHECK (plan_revision > 0),
    plan_sha256 text NOT NULL CHECK (plan_sha256 ~ '^[0-9a-f]{64}$'),
    request_sha256 text NOT NULL CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
    max_total_usd numeric(12,2) NOT NULL CHECK (max_total_usd > 0),
    approved_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, quote_id),
    UNIQUE (user_id, request_id),
    UNIQUE (user_id, id),
    FOREIGN KEY (user_id, quote_id) REFERENCES creative_generation_quotes(user_id, id) ON DELETE CASCADE
);

CREATE TABLE creative_generation_attempts (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    approval_id uuid NOT NULL,
    request_id uuid NOT NULL,
    status text NOT NULL CHECK (status IN ('reserved','succeeded','failed','unknown')),
    reserved_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    provider_receipt jsonb,
    error_code text,
    UNIQUE (user_id, approval_id),
    UNIQUE (user_id, request_id),
    FOREIGN KEY (user_id, approval_id) REFERENCES creative_generation_approvals(user_id, id) ON DELETE CASCADE,
    CHECK ((status = 'reserved' AND finished_at IS NULL)
        OR (status <> 'reserved' AND finished_at IS NOT NULL))
);

CREATE INDEX creative_generation_quotes_plan
    ON creative_generation_quotes(user_id, plan_id, created_at DESC);

CREATE FUNCTION creative_generation_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'creative generation quote and approval receipts are immutable';
END;
$$;
CREATE TRIGGER creative_generation_quote_immutable
    BEFORE UPDATE ON creative_generation_quotes
    FOR EACH ROW EXECUTE FUNCTION creative_generation_immutable();
CREATE TRIGGER creative_generation_approval_immutable
    BEFORE UPDATE ON creative_generation_approvals
    FOR EACH ROW EXECUTE FUNCTION creative_generation_immutable();

CREATE TRIGGER account_write_allowed BEFORE INSERT ON creative_generation_quotes
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed BEFORE INSERT ON creative_generation_approvals
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON creative_generation_attempts
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
