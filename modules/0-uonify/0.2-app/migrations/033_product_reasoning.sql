-- Semantic inference is separate from immutable source-reading history and its costs.
CREATE TABLE product_reasoning_jobs (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id),
 product_id uuid NOT NULL, material_job_id uuid REFERENCES product_material_jobs(id),
 google_subject text NOT NULL, fingerprint text NOT NULL, product_signature text NOT NULL,
 output_signature text, schema_hash text NOT NULL, status text NOT NULL
 CHECK(status IN ('queued','running','completed','error','unknown','stale')),
 revision integer NOT NULL, applied_revision integer, context jsonb NOT NULL, result jsonb NOT NULL DEFAULT '{}',
 lease_token uuid, lease_owner text, lease_until timestamptz,
 max_calls integer NOT NULL DEFAULT 6, max_tokens bigint NOT NULL DEFAULT 200000,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(user_id,product_id,fingerprint), FOREIGN KEY(user_id,product_id) REFERENCES products(user_id,id)
);
CREATE INDEX product_reasoning_queue ON product_reasoning_jobs(status,updated_at);
CREATE TABLE product_reasoning_calls (
 id uuid PRIMARY KEY, job_id uuid NOT NULL REFERENCES product_reasoning_jobs(id) ON DELETE CASCADE,
 lease_token uuid NOT NULL, phase text NOT NULL, state text NOT NULL CHECK(state IN ('running','done','error','unknown')),
 reserved_tokens bigint NOT NULL, total_tokens bigint NOT NULL DEFAULT 0,
 usage jsonb NOT NULL DEFAULT '{}', result jsonb NOT NULL DEFAULT '{}', acknowledged_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz
);
CREATE INDEX product_reasoning_calls_job ON product_reasoning_calls(job_id,phase,state);
ALTER TABLE uony_requests ADD COLUMN requirements_action jsonb;
