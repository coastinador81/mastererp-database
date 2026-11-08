-- Drive semantic recovery: immutable input, explicit commands, one business admission.
CREATE TABLE uony_semantic_requests (
    user_id uuid NOT NULL,
    logical_request_id uuid NOT NULL,
    thread_id text NOT NULL,
    google_subject text NOT NULL,
    project_id text NOT NULL,
    channel text NOT NULL CHECK (channel IN ('voice','text')),
    snapshot jsonb NOT NULL CHECK (jsonb_typeof(snapshot)='object'),
    scope jsonb NOT NULL CHECK (jsonb_typeof(scope)='object'),
    current_attempt_id uuid NOT NULL,
    action text,
    is_control boolean NOT NULL DEFAULT false,
    business_execution_id uuid,
    business_request_id uuid,
    execution_state text NOT NULL DEFAULT 'none'
      CHECK (execution_state IN ('none','admitted','started')),
    execution_lease_token uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(user_id,logical_request_id),
    UNIQUE(user_id,business_execution_id),
    UNIQUE(user_id,business_request_id),
    FOREIGN KEY(user_id,thread_id) REFERENCES uony_threads(user_id,id) ON DELETE CASCADE,
    CHECK ((business_execution_id IS NULL)=(business_request_id IS NULL)),
    CHECK ((execution_state='none')=(business_request_id IS NULL)),
    CHECK ((execution_state='started')=(execution_lease_token IS NOT NULL))
);
CREATE TABLE uony_semantic_attempts (
    user_id uuid NOT NULL,
    semantic_attempt_id uuid NOT NULL,
    logical_request_id uuid NOT NULL,
    recovery_command_id uuid,
    state text NOT NULL CHECK (state IN ('started','success','error','unknown')),
    decision jsonb,
    usage jsonb NOT NULL DEFAULT '{}'::jsonb,
    effective_semantic_model text,
    deadline_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(user_id,semantic_attempt_id),
    UNIQUE(user_id,logical_request_id,recovery_command_id),
    FOREIGN KEY(user_id,logical_request_id)
      REFERENCES uony_semantic_requests(user_id,logical_request_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX uony_semantic_one_active_attempt
  ON uony_semantic_attempts(user_id,logical_request_id) WHERE state='started';
CREATE TABLE uony_semantic_recovery_commands (
    user_id uuid NOT NULL,
    recovery_command_id uuid NOT NULL,
    logical_request_id uuid NOT NULL,
    semantic_attempt_id uuid,
    disposition text NOT NULL CHECK (disposition IN
      ('reclassified','reused','observing','reconciliation_required','blocked')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(user_id,recovery_command_id),
    FOREIGN KEY(user_id,logical_request_id)
      REFERENCES uony_semantic_requests(user_id,logical_request_id) ON DELETE CASCADE,
    FOREIGN KEY(user_id,semantic_attempt_id)
      REFERENCES uony_semantic_attempts(user_id,semantic_attempt_id)
);
CREATE INDEX uony_semantic_request_context ON uony_semantic_requests(user_id,thread_id,created_at DESC);
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_semantic_requests
  FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_semantic_attempts
  FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_semantic_recovery_commands
  FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
