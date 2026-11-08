-- Intake belongs to the conversation owner before a product exists.
CREATE TABLE uony_product_intakes (
    user_id uuid NOT NULL,
    id uuid NOT NULL,
    thread_id text NOT NULL,
    google_subject text NOT NULL,
    origin_request_id uuid NOT NULL,
    revision integer NOT NULL DEFAULT 1 CHECK (revision > 0),
    status text NOT NULL DEFAULT 'selecting' CHECK (status IN ('selecting','identified','linked')),
    folder_id text,
    folder_metadata jsonb,
    product_id uuid,
    created_product boolean NOT NULL DEFAULT false,
    confirmed_name text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,id),
    UNIQUE (user_id,origin_request_id),
    FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id),
    FOREIGN KEY (user_id,product_id) REFERENCES products(user_id,id),
    CHECK (folder_id IS NULL OR folder_id ~ '^[A-Za-z0-9_-]{1,200}$'),
    CHECK ((status='selecting' AND folder_id IS NULL AND folder_metadata IS NULL AND product_id IS NULL)
        OR (status='identified' AND folder_id IS NOT NULL AND folder_metadata IS NOT NULL AND product_id IS NULL)
        OR (status='linked' AND folder_id IS NOT NULL AND folder_metadata IS NOT NULL AND product_id IS NOT NULL)),
    CHECK (NOT created_product OR status='linked'),
    CHECK (folder_metadata IS NULL OR (jsonb_typeof(folder_metadata)='object'
        AND folder_metadata ?& ARRAY['id','name'] AND folder_metadata - ARRAY['id','name'] = '{}'::jsonb
        AND folder_metadata->>'id'=folder_id AND jsonb_typeof(folder_metadata->'name')='string'
        AND char_length(folder_metadata->>'name') BETWEEN 1 AND 500))
);
CREATE UNIQUE INDEX uony_product_intakes_active ON uony_product_intakes(user_id,thread_id)
    WHERE status IN ('selecting','identified');
CREATE INDEX uony_product_intakes_folder ON uony_product_intakes(user_id,google_subject,folder_id)
    WHERE product_id IS NOT NULL;

CREATE TABLE uony_product_intake_requests (
    user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    intake_id uuid NOT NULL,
    operation text NOT NULL CHECK (operation IN ('folder','product')),
    fingerprint text NOT NULL CHECK (fingerprint ~ '^[a-f0-9]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,request_id),
    FOREIGN KEY (user_id,intake_id) REFERENCES uony_product_intakes(user_id,id) ON DELETE CASCADE
);

ALTER TABLE uony_requests ADD COLUMN product_intake jsonb;
ALTER TABLE uony_requests ADD CONSTRAINT uony_product_intake_valid CHECK (
    product_intake IS NULL OR (jsonb_typeof(product_intake)='object'
        AND product_intake ?& ARRAY['id','revision']
        AND product_intake - ARRAY['id','revision'] = '{}'::jsonb
        AND jsonb_typeof(product_intake->'id')='string'
        AND product_intake->>'id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND jsonb_typeof(product_intake->'revision')='number'
        AND product_intake->>'revision' ~ '^[1-9][0-9]*$'));
