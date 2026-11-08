-- Read-only questions about an existing request do not acquire an execution
-- lease. A committed receipt reserves their one semantic inference attempt.
CREATE TABLE uony_written_followups (
    user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    target_request_id uuid NOT NULL,
    thread_id text NOT NULL,
    google_subject text NOT NULL,
    project_id text NOT NULL,
    connection_fingerprint text NOT NULL CHECK (length(connection_fingerprint)=64),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload)='object'),
    model text NOT NULL,
    selection_reason text NOT NULL,
    state text NOT NULL CHECK (state IN ('started','success','error','unknown')),
    semantic_decision jsonb CHECK (semantic_decision IS NULL OR jsonb_typeof(semantic_decision)='object'),
    usage jsonb NOT NULL DEFAULT '{}'::jsonb,
    error_code text,
    provider_started_at timestamptz,
    deadline_at timestamptz NOT NULL DEFAULT now()+interval '2 minutes',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    PRIMARY KEY (user_id,request_id),
    FOREIGN KEY (user_id,target_request_id) REFERENCES uony_requests(user_id,request_id) ON DELETE CASCADE,
    FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id) ON DELETE CASCADE,
    CHECK (request_id<>target_request_id),
    CHECK ((state='started')=(finished_at IS NULL))
);
CREATE UNIQUE INDEX uony_written_followup_one_active
    ON uony_written_followups(user_id) WHERE state='started';
CREATE INDEX uony_written_followup_recent
    ON uony_written_followups(user_id,created_at DESC);
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_written_followups
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
