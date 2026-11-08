-- Final voice turns share the existing conversation owner and deletion boundary.
-- A Live session cannot create a product, request, or queued job by persisting text.
CREATE TABLE uony_live_turns (
 user_id uuid NOT NULL,
 thread_id text NOT NULL,
 session_id uuid NOT NULL,
 turn_id uuid NOT NULL,
 role text NOT NULL CHECK (role IN ('user','assistant')),
 text text NOT NULL CHECK (char_length(text) BETWEEN 1 AND 3000),
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (user_id,thread_id,session_id,turn_id,role),
 FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id)
);
CREATE INDEX uony_live_turns_recent ON uony_live_turns(user_id,thread_id,created_at DESC);
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_live_turns
 FOR EACH ROW EXECUTE FUNCTION account_write_allowed();

-- One paid Live session per account. Expiration fences process crashes.
CREATE TABLE uony_live_sessions (
 user_id uuid PRIMARY KEY REFERENCES users(id),
 session_id uuid NOT NULL,
 thread_id text NOT NULL,
 expires_at timestamptz NOT NULL
);
CREATE INDEX uony_live_sessions_active ON uony_live_sessions(expires_at);
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_live_sessions
 FOR EACH ROW EXECUTE FUNCTION account_write_allowed();

-- Provider usage is the latest observed metadata, not a final invoice.
CREATE TABLE uony_live_usage (
 user_id uuid NOT NULL,
 session_id uuid NOT NULL,
 thread_id text NOT NULL,
 state text NOT NULL CHECK (state IN ('started','observed','unknown')),
 usage jsonb NOT NULL DEFAULT '{}',
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (user_id,session_id),
 FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id)
);
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_live_usage
 FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
