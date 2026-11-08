-- Durable queue: each worker owns an expiring token; callbacks are fenced by it.
ALTER TABLE product_material_jobs DROP CONSTRAINT product_material_jobs_status_check;
ALTER TABLE product_material_jobs ADD CONSTRAINT product_material_jobs_status_check
    CHECK(status IN ('queued','running','paused','ready','error'));
ALTER TABLE product_material_jobs
    ADD COLUMN lease_token uuid,
    ADD COLUMN lease_owner text,
    ADD COLUMN lease_until timestamptz,
    ADD COLUMN pause_requested boolean NOT NULL DEFAULT false,
    ADD COLUMN max_calls integer NOT NULL DEFAULT 200 CHECK(max_calls > 0),
    ADD COLUMN max_tokens bigint NOT NULL DEFAULT 1000000 CHECK(max_tokens > 0);
CREATE INDEX product_material_jobs_queue ON product_material_jobs(status, updated_at);
CREATE TABLE product_material_sources (
    job_id uuid NOT NULL REFERENCES product_material_jobs(id) ON DELETE CASCADE,
    source_id text NOT NULL,
    version text NOT NULL,
    data jsonb NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(job_id, source_id)
);
CREATE TABLE product_material_fragments (
    job_id uuid NOT NULL REFERENCES product_material_jobs(id) ON DELETE CASCADE,
    id text NOT NULL,
    source_id text NOT NULL,
    version text NOT NULL,
    locator text NOT NULL,
    state text NOT NULL CHECK(state IN ('pending','running','done','partial','split','error','unknown','superseded')),
    payload jsonb NOT NULL,
    result jsonb NOT NULL DEFAULT '{}',
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(job_id,id),
    FOREIGN KEY(job_id,source_id) REFERENCES product_material_sources(job_id,source_id) ON DELETE CASCADE
);
CREATE INDEX product_material_fragments_pending ON product_material_fragments(job_id,state);
CREATE TABLE product_material_calls (
    id uuid PRIMARY KEY,
    job_id uuid NOT NULL REFERENCES product_material_jobs(id) ON DELETE CASCADE,
    lease_token uuid NOT NULL,
    fragment_ids jsonb NOT NULL,
    state text NOT NULL CHECK(state IN ('running','done','error','unknown')),
    reserved_tokens bigint NOT NULL,
    total_tokens bigint NOT NULL DEFAULT 0,
    usage jsonb NOT NULL DEFAULT '{}',
    result jsonb NOT NULL DEFAULT '{}',
    acknowledged_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz
);
CREATE INDEX product_material_calls_job ON product_material_calls(job_id,state);
CREATE TABLE product_material_controls (
    user_id uuid NOT NULL REFERENCES users(id),
    request_id uuid NOT NULL,
    job_id uuid NOT NULL REFERENCES product_material_jobs(id) ON DELETE CASCADE,
    action text NOT NULL CHECK(action IN ('pause','resume')),
    payload jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(user_id,request_id)
);
-- Old in-flight processes have no lease: stop visibly, never repeat paid calls on startup.
UPDATE product_material_jobs SET status='paused',result=result ||
    '{"stage":"paused","pauseReason":"legacy_interrupted","canResume":true}'::jsonb
    WHERE status='running';
