CREATE TABLE uony_live_semantic_receipts (
    user_id uuid NOT NULL,
    thread_id text NOT NULL,
    session_id uuid NOT NULL,
    turn_id uuid NOT NULL,
    role text NOT NULL DEFAULT 'user' CHECK (role='user'),
    text_sha256 text NOT NULL CHECK (length(text_sha256)=64),
    state text NOT NULL CHECK (state IN ('started','success','error','unknown')),
    decision jsonb,
    usage jsonb NOT NULL DEFAULT '{}'::jsonb,
    elapsed_ms integer CHECK (elapsed_ms>=0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,session_id,turn_id),
    FOREIGN KEY (user_id,thread_id,session_id,turn_id,role)
      REFERENCES uony_live_turns(user_id,thread_id,session_id,turn_id,role) ON DELETE CASCADE,
    CHECK (decision IS NULL OR jsonb_typeof(decision)='object')
);
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_live_semantic_receipts
FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
