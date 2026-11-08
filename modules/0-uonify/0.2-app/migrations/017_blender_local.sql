CREATE TABLE blender_agents (
 id uuid PRIMARY KEY,
 token_hash text NOT NULL UNIQUE,
 device_name text NOT NULL,
 user_id uuid REFERENCES users(id),
 pair_expires_at timestamptz NOT NULL,
 paired_at timestamptz,
 revoked_at timestamptz,
 last_seen_at timestamptz,
 available boolean NOT NULL DEFAULT false,
 blender_version text,
 capabilities jsonb NOT NULL DEFAULT '[]',
 scene jsonb,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX blender_active_user ON blender_agents(user_id)
 WHERE user_id IS NOT NULL AND revoked_at IS NULL;
CREATE TABLE blender_jobs (
 id uuid PRIMARY KEY,
 user_id uuid NOT NULL REFERENCES users(id),
 agent_id uuid NOT NULL REFERENCES blender_agents(id),
 request_id uuid NOT NULL,
 operation text NOT NULL CHECK(operation IN ('inspect_scene','render_preview')),
 source text NOT NULL CHECK(source IN ('nexus','uony')),
 status text NOT NULL DEFAULT 'queued'
  CHECK(status IN ('queued','running','completed','failed','unknown')),
 result jsonb,
 error text,
 preview bytea CHECK(octet_length(preview)<=1048576),
 report_hash text,
 local_duration_ms integer CHECK(local_duration_ms BETWEEN 0 AND 180000),
 created_at timestamptz NOT NULL DEFAULT now(),
 started_at timestamptz,
 lease_expires_at timestamptz,
 finished_at timestamptz,
 UNIQUE(user_id,request_id)
);
CREATE INDEX blender_job_queue ON blender_jobs(agent_id,created_at)
 WHERE status IN ('queued','running');
CREATE TABLE blender_coordination_usage (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 user_id uuid NOT NULL REFERENCES users(id),
 operation text NOT NULL,
 request_bytes bigint NOT NULL CHECK(request_bytes>=0),
 response_bytes bigint NOT NULL CHECK(response_bytes>=0),
 backend_duration_ms integer NOT NULL CHECK(backend_duration_ms>=0),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX blender_usage_user ON blender_coordination_usage(user_id,created_at);
