CREATE TABLE amazon_incident_sync (
 user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 seller_id text NOT NULL, marketplace_id text NOT NULL,
 state text NOT NULL DEFAULT 'never', last_checked_at timestamptz, message text,
 scan_id uuid, cursor text, page_token text, seen_tokens jsonb NOT NULL DEFAULT '[]',
 scan_started_at timestamptz, PRIMARY KEY(user_id,seller_id,marketplace_id)
);
CREATE TABLE amazon_listing_snapshots (
 user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 seller_id text NOT NULL, marketplace_id text NOT NULL, sku text NOT NULL,
 data jsonb NOT NULL, fetched_at timestamptz NOT NULL, upstream_updated_at timestamptz,
 version bigint NOT NULL DEFAULT 1, scan_id uuid,
 PRIMARY KEY(user_id,seller_id,marketplace_id,sku)
);
CREATE TABLE amazon_incident_checks (
 user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 seller_id text NOT NULL, marketplace_id text NOT NULL, sku text NOT NULL,
 state text NOT NULL DEFAULT 'never', last_checked_at timestamptz, message text,
 PRIMARY KEY(user_id,seller_id,marketplace_id,sku)
);
CREATE TABLE amazon_incidents (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 seller_id text NOT NULL, marketplace_id text NOT NULL, sku text NOT NULL,
 issue_key text NOT NULL, code text NOT NULL, message text NOT NULL,
 severity text NOT NULL, attribute_names jsonb NOT NULL DEFAULT '[]', raw_issue jsonb NOT NULL,
 product_name text NOT NULL, product_type text, product_id uuid,
 status text NOT NULL DEFAULT 'needs_attention' CHECK(status IN
 ('needs_attention','correction_ready','awaiting_amazon','resolved')),
 revision integer NOT NULL DEFAULT 1, first_seen_at timestamptz NOT NULL DEFAULT now(),
 last_seen_at timestamptz NOT NULL DEFAULT now(), last_checked_at timestamptz,
 resolved_at timestamptz, correction jsonb, submission_status text, submission_issues jsonb NOT NULL DEFAULT '[]',
 history jsonb NOT NULL DEFAULT '[]', UNIQUE(user_id,seller_id,marketplace_id,sku,issue_key)
);
CREATE INDEX amazon_incidents_user_status ON amazon_incidents(user_id,seller_id,marketplace_id,status);
CREATE TABLE amazon_incident_requests (
 user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 request_id text NOT NULL, incident_id uuid NOT NULL REFERENCES amazon_incidents(id),
 operation text NOT NULL, fingerprint text NOT NULL, result jsonb,
 created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(user_id,request_id)
);
CREATE TABLE amazon_incident_submissions (
 id uuid PRIMARY KEY, incident_id uuid NOT NULL REFERENCES amazon_incidents(id),
 user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 seller_id text NOT NULL, marketplace_id text NOT NULL, sku text NOT NULL,
 request_id text NOT NULL, attributes jsonb NOT NULL, schema_hash text NOT NULL,
 baseline_updated_at timestamptz, sent_at timestamptz NOT NULL,
 status text NOT NULL CHECK(status IN ('sending','accepted','unknown','rejected','confirmed','needs_attention')),
 submission_id text, response jsonb, request_receipt text,
 UNIQUE(user_id,request_id)
);
ALTER TABLE uony_requests ADD COLUMN incident_action jsonb;
