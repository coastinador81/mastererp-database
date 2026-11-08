-- A model may propose a local product change, but only a separate typed
-- customer decision may apply it. This is independent of Amazon publication.
CREATE TABLE uony_product_proposals (
    user_id uuid NOT NULL,
    origin_request_id uuid NOT NULL,
    thread_id text NOT NULL,
    google_subject text NOT NULL,
    google_project_id text NOT NULL,
    action text NOT NULL CHECK (action IN ('create','update')),
    target_sku text NOT NULL CHECK (char_length(target_sku) BETWEEN 1 AND 80),
    target_product_id uuid,
    base_revision integer,
    thread_link_version integer NOT NULL CHECK (thread_link_version >= 0),
    focus_cutoff_at timestamptz,
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload)='object'),
    proposal_hash text NOT NULL CHECK (proposal_hash ~ '^[a-f0-9]{64}$'),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','approved','rejected','cancelled')),
    decision_request_id uuid,
    decision_at timestamptz,
    decision_result jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,origin_request_id),
    FOREIGN KEY (user_id,origin_request_id)
        REFERENCES uony_requests(user_id,request_id) ON DELETE CASCADE,
    FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id),
    FOREIGN KEY (user_id,target_product_id) REFERENCES products(user_id,id),
    CHECK ((action='create' AND target_product_id IS NULL AND base_revision IS NULL)
        OR (action='update' AND target_product_id IS NOT NULL AND base_revision > 0)),
    CHECK ((status='pending' AND decision_request_id IS NULL AND decision_at IS NULL
            AND decision_result IS NULL)
        OR (status IN ('approved','rejected','cancelled') AND decision_request_id IS NOT NULL
            AND decision_at IS NOT NULL AND decision_result IS NOT NULL))
);
CREATE UNIQUE INDEX uony_product_proposal_decision_once
    ON uony_product_proposals(user_id,decision_request_id)
    WHERE decision_request_id IS NOT NULL;
CREATE INDEX uony_product_proposals_pending
    ON uony_product_proposals(user_id,google_subject,thread_id,created_at DESC)
    WHERE status='pending';

ALTER TABLE uony_requests ADD COLUMN product_proposal jsonb;

-- An approved proposal is an explicit customer action in this thread.
ALTER TABLE uony_thread_products DROP CONSTRAINT uony_thread_products_source_check;
ALTER TABLE uony_thread_products ADD CONSTRAINT uony_thread_products_source_check
    CHECK (source IN ('conversation','intake','approval'));
