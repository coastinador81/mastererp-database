-- Operational observations contain no prompts, tokens, transcripts or credentials.
-- Job identity remains PostgreSQL-authoritative; Redis is not a lease authority.
CREATE TABLE uony_conversation_workers (
    worker_id text PRIMARY KEY CHECK (char_length(worker_id) BETWEEN 1 AND 160),
    engines text[] NOT NULL CHECK (engines <@ ARRAY['classic','adk']::text[]),
    status text NOT NULL CHECK (status IN ('idle','running','stopped')),
    started_at timestamptz NOT NULL DEFAULT now(),
    heartbeat_at timestamptz NOT NULL DEFAULT now(),
    stopped_at timestamptz
);
CREATE INDEX uony_conversation_workers_heartbeat
    ON uony_conversation_workers (heartbeat_at);

CREATE TABLE uony_conversation_recoveries (
    user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    claim_count integer NOT NULL CHECK (claim_count >= 0),
    engine text NOT NULL CHECK (engine IN ('classic','adk')),
    outcome text NOT NULL CHECK (outcome IN ('queued','error','unknown')),
    expired_at timestamptz,
    recovered_at timestamptz NOT NULL DEFAULT now(),
    resumed_at timestamptz,
    PRIMARY KEY (user_id,request_id,claim_count),
    FOREIGN KEY (user_id,request_id)
        REFERENCES uony_conversation_jobs(user_id,request_id) ON DELETE CASCADE
);
CREATE INDEX uony_conversation_recoveries_recent
    ON uony_conversation_recoveries(user_id,recovered_at DESC);

-- Used only by an explicit, offline restore operation; normal startup never
-- quarantines jobs. A historical snapshot cannot prove later external effects.
CREATE TABLE uony_queue_restore_operations (
    id uuid PRIMARY KEY,
    backup_reference text NOT NULL CHECK (char_length(backup_reference) BETWEEN 1 AND 200),
    operator_reference text NOT NULL CHECK (char_length(operator_reference) BETWEEN 1 AND 200),
    quarantined_count integer NOT NULL CHECK (quarantined_count>=0),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE uony_queue_restore_quarantines (
    restore_id uuid NOT NULL REFERENCES uony_queue_restore_operations(id),
    user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    prior_status text NOT NULL CHECK (prior_status IN ('queued','running')),
    PRIMARY KEY (restore_id,user_id,request_id),
    FOREIGN KEY (user_id,request_id)
        REFERENCES uony_conversation_jobs(user_id,request_id) ON DELETE CASCADE
);
