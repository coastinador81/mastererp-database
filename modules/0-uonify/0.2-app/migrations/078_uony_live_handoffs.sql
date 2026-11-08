-- A confirmed voice turn may be routed once to the existing conversation job.
-- This is a causal link, not consent to create a product or inspect Drive.
CREATE TABLE uony_live_handoffs (
    user_id uuid NOT NULL,
    thread_id text NOT NULL,
    session_id uuid NOT NULL,
    turn_id uuid NOT NULL,
    role text NOT NULL DEFAULT 'user' CHECK (role='user'),
    request_id uuid NOT NULL,
    google_subject text NOT NULL,
    google_project_id text NOT NULL,
    intent text NOT NULL CHECK (intent IN ('create_product','use_drive_materials')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,session_id,turn_id),
    UNIQUE (user_id,request_id),
    FOREIGN KEY (user_id,thread_id,session_id,turn_id,role)
        REFERENCES uony_live_turns(user_id,thread_id,session_id,turn_id,role)
        ON DELETE CASCADE,
    FOREIGN KEY (user_id,request_id) REFERENCES uony_requests(user_id,request_id)
        ON DELETE CASCADE
);
CREATE INDEX uony_live_handoffs_thread ON uony_live_handoffs(user_id,thread_id,created_at DESC);
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_live_handoffs
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
