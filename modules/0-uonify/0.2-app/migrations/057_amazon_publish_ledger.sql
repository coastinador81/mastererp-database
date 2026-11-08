-- AMZ-04: exact-revision consent and one reserved Listings PUT per approval.
-- The production send gate stays closed; this schema never invokes Amazon.
ALTER TABLE amazon_publish_snapshots
    ADD CONSTRAINT amazon_publish_snapshots_owner_key UNIQUE (user_id, id);

CREATE TABLE amazon_publish_approvals (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    product_id uuid NOT NULL,
    snapshot_id uuid NOT NULL,
    request_id uuid NOT NULL,
    actor_id uuid NOT NULL,
    product_revision integer NOT NULL CHECK (product_revision > 0),
    sku text NOT NULL,
    seller_id text NOT NULL,
    marketplace_id text NOT NULL,
    product_type text NOT NULL,
    schema_hash text NOT NULL CHECK (schema_hash ~ '^[0-9a-f]{64}$'),
    payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
    snapshot_hash text NOT NULL CHECK (snapshot_hash ~ '^[0-9a-f]{64}$'),
    approved_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, request_id),
    UNIQUE (user_id, snapshot_id),
    UNIQUE (user_id, id),
    FOREIGN KEY (user_id, snapshot_id)
        REFERENCES amazon_publish_snapshots(user_id, id) ON DELETE CASCADE
);

-- Filled only by a future trusted asset check, never by a client approval.
-- A URL alone is not proof that Amazon can fetch it or that the seller owns it.
CREATE TABLE amazon_publish_media_verifications (
    user_id uuid NOT NULL,
    snapshot_id uuid NOT NULL,
    media_refs_hash text NOT NULL CHECK (media_refs_hash ~ '^[0-9a-f]{64}$'),
    verification_method text NOT NULL CHECK (verification_method = 'asset_service'),
    verified_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, snapshot_id),
    FOREIGN KEY (user_id, snapshot_id)
        REFERENCES amazon_publish_snapshots(user_id, id) ON DELETE CASCADE
);

CREATE TABLE amazon_publish_attempts (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    approval_id uuid NOT NULL,
    request_id uuid NOT NULL,
    status text NOT NULL CHECK (status IN ('reserved','accepted_initial','invalid','unknown')),
    reserved_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    submission_id text,
    request_receipt text,
    issues jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(issues) = 'array'),
    error_code text,
    UNIQUE (user_id, approval_id),
    UNIQUE (user_id, request_id),
    FOREIGN KEY (user_id, approval_id) REFERENCES amazon_publish_approvals(user_id, id) ON DELETE CASCADE,
    CHECK ((status = 'reserved' AND finished_at IS NULL)
        OR (status <> 'reserved' AND finished_at IS NOT NULL))
);

CREATE INDEX amazon_publish_approvals_product
    ON amazon_publish_approvals(user_id, product_id, approved_at DESC);
CREATE INDEX amazon_publish_attempts_status
    ON amazon_publish_attempts(status, reserved_at);

CREATE FUNCTION amazon_publish_approval_no_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'amazon_publish_approvals are immutable';
END;
$$;
CREATE TRIGGER amazon_publish_approval_immutable
    BEFORE UPDATE ON amazon_publish_approvals
    FOR EACH ROW EXECUTE FUNCTION amazon_publish_approval_no_update();
