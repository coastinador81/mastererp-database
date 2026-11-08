ALTER TABLE users ADD COLUMN onboarding_completed_at timestamptz;
CREATE TABLE uony_requests (
 user_id uuid NOT NULL REFERENCES users(id),
 request_id uuid NOT NULL,
 thread_id text NOT NULL,
 prompt text NOT NULL,
 reply text,
 status text NOT NULL CHECK(status IN ('running','success','error')),
 error_code text,
 model text NOT NULL,
 project_id text NOT NULL,
 usage jsonb NOT NULL DEFAULT '{}',
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(user_id,request_id)
);
CREATE INDEX uony_history ON uony_requests(user_id,created_at);
