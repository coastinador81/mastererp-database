-- Following up a saved product is separate from its authoritative facts.
-- This append-only log never marks a product, requirement or Amazon listing done.
CREATE TABLE uony_return_followups (
    user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    thread_id text NOT NULL,
    product_id uuid NOT NULL,
    google_subject text NOT NULL,
    version integer NOT NULL CHECK (version > 0),
    action text NOT NULL CHECK (action IN ('defer','resolve')),
    pending_id text NOT NULL CHECK (char_length(pending_id) BETWEEN 1 AND 120),
    product_revision integer NOT NULL CHECK (product_revision > 0),
    source_fingerprint text NOT NULL CHECK (source_fingerprint ~ '^[0-9a-f]{64}$'),
    payload jsonb NOT NULL,
    pending_snapshot jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,request_id),
    UNIQUE (user_id,thread_id,product_id,version),
    FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id),
    FOREIGN KEY (user_id,product_id) REFERENCES products(user_id,id)
);
CREATE INDEX uony_return_followups_history
    ON uony_return_followups(user_id,thread_id,product_id,version DESC);
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_return_followups
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
