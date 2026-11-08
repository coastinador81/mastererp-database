-- Drive scope emitted by the server for one admitted request (audit F0.1, 20-10-2026).
-- Only Drive ids and the operation: never names, the customer's words or document
-- content. The words that admitted it stay in uony_requests (text) or
-- uony_live_turns (voice), joined by request_id; the scope never copies them.
-- The read tools act only inside an unexpired scope; one scope per request at most.
CREATE TABLE uony_drive_scopes (
    user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    operation text NOT NULL CHECK (operation IN ('count','list','read')),
    target_kind text NOT NULL CHECK (target_kind IN ('account','folder','file')),
    target_id text CHECK (target_id ~ '^[A-Za-z0-9_-]{1,200}$'),
    drive_id text CHECK (drive_id ~ '^[A-Za-z0-9_-]{1,200}$'),
    source text NOT NULL CHECK (source IN ('voice_call','text_agent','server_metadata')),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (user_id, request_id),
    FOREIGN KEY (user_id, request_id) REFERENCES uony_requests(user_id, request_id) ON DELETE CASCADE,
    CHECK ((target_kind = 'account') = (target_id IS NULL)),
    CHECK (target_kind <> 'account' OR operation = 'count'),
    CHECK (target_kind <> 'file' OR operation = 'read'),
    CHECK (expires_at > created_at)
);
CREATE INDEX uony_drive_scopes_expiry ON uony_drive_scopes (expires_at);

-- A typed spoken Drive request: the model proposes the operation, the server
-- admits it against the primary final transcript and resolves the resource.
ALTER TABLE uony_live_handoffs
    ADD COLUMN drive_operation text
    CHECK (drive_operation IN ('access','count','list','read'));
ALTER TABLE uony_live_handoffs
    DROP CONSTRAINT uony_live_handoffs_intent_check;
ALTER TABLE uony_live_handoffs
    ADD CONSTRAINT uony_live_handoffs_intent_check
    CHECK (intent IN ('create_product', 'use_drive_materials', 'creative_plan',
                      'semantic_request', 'drive_request'));
ALTER TABLE uony_live_handoffs
    ADD CONSTRAINT uony_live_handoffs_drive_request_check
    CHECK ((intent = 'drive_request') = (drive_operation IS NOT NULL));
