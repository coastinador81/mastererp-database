-- AMZ-03: immutable, owner-scoped preparation of the exact Listings Items body.
-- Deletion remains possible for product/account erasure; updates are prohibited.
CREATE TABLE amazon_publish_snapshots (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    product_id uuid NOT NULL,
    product_revision integer NOT NULL CHECK (product_revision > 0),
    sku text NOT NULL,
    seller_id text NOT NULL,
    marketplace_id text NOT NULL,
    product_type text NOT NULL,
    schema_hash text NOT NULL CHECK (schema_hash ~ '^[0-9a-f]{64}$'),
    payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
    snapshot_hash text NOT NULL CHECK (snapshot_hash ~ '^[0-9a-f]{64}$'),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    media_refs jsonb NOT NULL CHECK (jsonb_typeof(media_refs) = 'array'),
    local_issues jsonb NOT NULL CHECK (jsonb_typeof(local_issues) = 'array'),
    local_validation text NOT NULL CHECK (local_validation IN ('valid', 'needs_input')),
    media_readiness text NOT NULL CHECK (media_readiness IN ('missing', 'unverified', 'invalid')),
    prepared_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, product_id, snapshot_hash),
    FOREIGN KEY (user_id, product_id, product_revision)
        REFERENCES product_revisions(user_id, product_id, revision) ON DELETE CASCADE
);

CREATE INDEX amazon_publish_snapshots_latest
    ON amazon_publish_snapshots(user_id, product_id, prepared_at DESC, id DESC);

CREATE FUNCTION amazon_publish_snapshot_no_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'amazon_publish_snapshots are immutable';
END;
$$;
CREATE TRIGGER amazon_publish_snapshot_immutable
    BEFORE UPDATE ON amazon_publish_snapshots
    FOR EACH ROW EXECUTE FUNCTION amazon_publish_snapshot_no_update();
