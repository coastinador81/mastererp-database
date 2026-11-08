-- AMZ-05: durable read-only observations after a Listings PUT receipt.
-- A GET observation is independent of the immutable Listings PUT receipt.
ALTER TABLE amazon_publish_attempts
    ADD CONSTRAINT amazon_publish_attempts_owner_key UNIQUE (user_id, id);

CREATE TABLE amazon_publish_followups (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    attempt_id uuid NOT NULL,
    request_id uuid NOT NULL,
    status text NOT NULL CHECK (status IN ('checking','done','read_error')),
    result text CHECK (result IN ('not_found','listing_present','issues','visible_current','unmatched')),
    started_at timestamptz NOT NULL DEFAULT now(),
    checked_at timestamptz,
    listing_status jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(listing_status) = 'array'),
    issues jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(issues) = 'array'),
    asin text,
    listing_updated_at timestamptz,
    product_type_match boolean,
    snapshot_match boolean,
    listing_fingerprint text CHECK (listing_fingerprint IS NULL OR listing_fingerprint ~ '^[0-9a-f]{64}$'),
    error_code text,
    UNIQUE (user_id, request_id),
    FOREIGN KEY (user_id, attempt_id)
        REFERENCES amazon_publish_attempts(user_id, id) ON DELETE CASCADE,
    CHECK ((status = 'checking' AND checked_at IS NULL AND result IS NULL)
        OR (status = 'done' AND checked_at IS NOT NULL AND result IS NOT NULL AND error_code IS NULL)
        OR (status = 'read_error' AND checked_at IS NOT NULL AND result IS NULL AND error_code IS NOT NULL))
);

CREATE UNIQUE INDEX amazon_publish_followups_one_active
    ON amazon_publish_followups(attempt_id) WHERE status = 'checking';
CREATE INDEX amazon_publish_followups_timeline
    ON amazon_publish_followups(user_id,attempt_id,checked_at DESC,id DESC);

CREATE FUNCTION amazon_publish_followup_no_rewrite() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status <> 'checking' OR NEW.id <> OLD.id OR NEW.user_id <> OLD.user_id
        OR NEW.attempt_id <> OLD.attempt_id OR NEW.request_id <> OLD.request_id
        OR NEW.started_at <> OLD.started_at THEN
        RAISE EXCEPTION 'amazon_publish_followups completed observations are immutable';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER amazon_publish_followups_immutable
    BEFORE UPDATE ON amazon_publish_followups
    FOR EACH ROW EXECUTE FUNCTION amazon_publish_followup_no_rewrite();
