-- An explicit choice binds one conversation to one product. Facts remain in
-- products/materials and are projected at read time, never copied here.
CREATE TABLE uony_thread_products (
    user_id uuid NOT NULL,
    thread_id text NOT NULL,
    product_id uuid NOT NULL,
    google_subject text NOT NULL,
    linked_revision integer NOT NULL CHECK (linked_revision > 0),
    version integer NOT NULL DEFAULT 1 CHECK (version > 0),
    source text NOT NULL CHECK (source IN ('conversation','intake')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,thread_id),
    FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id),
    FOREIGN KEY (user_id,product_id) REFERENCES products(user_id,id)
);
CREATE INDEX uony_thread_products_product ON uony_thread_products(user_id,product_id);

ALTER TABLE uony_requests ADD COLUMN product_action jsonb;
ALTER TABLE uony_requests ADD CONSTRAINT uony_product_action_valid CHECK (
    product_action IS NULL OR (jsonb_typeof(product_action)='object'
        AND product_action ?& ARRAY['action','sku','revision','expectedVersion']
        AND product_action - ARRAY['action','sku','revision','expectedVersion'] = '{}'::jsonb
        AND product_action->>'action'='link'
        AND jsonb_typeof(product_action->'sku')='string'
        AND char_length(product_action->>'sku') BETWEEN 1 AND 80
        AND jsonb_typeof(product_action->'revision')='number'
        AND product_action->>'revision' ~ '^[1-9][0-9]*$'
        AND jsonb_typeof(product_action->'expectedVersion')='number'
        AND product_action->>'expectedVersion' ~ '^(0|[1-9][0-9]*)$'));
