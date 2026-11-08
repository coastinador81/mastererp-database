-- Conversation work survives the HTTP connection. A started provider call is
-- never replayed after a lost lease because its consumption may be unknown.
CREATE TABLE uony_conversation_jobs (
    user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    thread_id text NOT NULL,
    google_subject text NOT NULL,
    project_id text NOT NULL,
    payload jsonb NOT NULL,
    memory_snapshot jsonb,
    status text NOT NULL CHECK (status IN ('queued','running','success','error','unknown','cancelled')),
    lease_token uuid,
    lease_owner text,
    lease_until timestamptz,
    claim_count integer NOT NULL DEFAULT 0 CHECK (claim_count>=0),
    available_at timestamptz NOT NULL DEFAULT now(),
    provider_started_at timestamptz,
    provider_completed_at timestamptz,
    retry_of uuid,
    acknowledged_at timestamptz,
    usage jsonb NOT NULL DEFAULT '{}'::jsonb,
    error_code text,
    provider_error_code text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,request_id),
    FOREIGN KEY (user_id,request_id) REFERENCES uony_requests(user_id,request_id) ON DELETE CASCADE,
    FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id)
);
CREATE UNIQUE INDEX uony_conversation_one_active_per_user
    ON uony_conversation_jobs(user_id) WHERE status IN ('queued','running');
CREATE INDEX uony_conversation_claim
    ON uony_conversation_jobs(status,created_at) WHERE status='queued';
CREATE INDEX uony_conversation_recent
    ON uony_conversation_jobs(user_id,created_at DESC);
CREATE UNIQUE INDEX uony_conversation_one_retry
    ON uony_conversation_jobs(user_id,retry_of) WHERE retry_of IS NOT NULL;

-- Older synchronous attempts have no durable reservation. Their outcome is
-- uncertain, so migration must never enqueue or replay them.
INSERT INTO uony_conversation_jobs(user_id,request_id,thread_id,google_subject,
    project_id,payload,status,provider_started_at,usage,error_code,created_at)
SELECT r.user_id,r.request_id,r.thread_id,u.google_subject,r.project_id,
    jsonb_build_object('requestId',r.request_id::text,'threadId',r.thread_id,
        'text',r.prompt,'projectId',t.project_id::text,'model',r.requested_model,
        'effort',r.effort,'productContext',r.product_context,'retryOf',NULL,
        'productAction',r.product_action,'formResponse',r.form_response,
        'incidentAction',r.incident_action,'materialAction',r.material_action,
        'requirementsAction',r.requirements_action),
    'unknown',r.created_at,'{"attemptedCalls":1,"uncertainCalls":1}'::jsonb,
    'consumption_unknown',r.created_at
FROM uony_requests r JOIN users u ON u.id=r.user_id
JOIN uony_threads t ON t.user_id=r.user_id AND t.id=r.thread_id
WHERE r.status='running';
UPDATE uony_requests SET status='error',error_code='consumption_unknown',
    usage=coalesce(usage,'{}'::jsonb) || '{"uncertainCalls":1}'::jsonb
WHERE status='running';
