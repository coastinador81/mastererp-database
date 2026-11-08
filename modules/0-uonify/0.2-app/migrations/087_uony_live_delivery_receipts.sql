-- Delivery receipts contain no audio, transcript or provider credentials.
CREATE TABLE uony_live_deliveries (
 user_id uuid NOT NULL,
 request_id uuid NOT NULL,
 event_id uuid NOT NULL UNIQUE,
 session_id uuid NOT NULL,
 state text NOT NULL CHECK (state IN
   ('rendering','sending','acknowledged','interrupted','unknown','error')),
 usage_state text NOT NULL DEFAULT 'started' CHECK (usage_state IN ('started','observed','unknown')),
 usage jsonb NOT NULL DEFAULT '{}',
 created_at timestamptz NOT NULL DEFAULT now(),
 rendered_at timestamptz,
 sent_at timestamptz,
 acknowledged_at timestamptz,
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(user_id,request_id),
 FOREIGN KEY(user_id,request_id) REFERENCES uony_live_handoffs(user_id,request_id) ON DELETE CASCADE
);
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_live_deliveries
 FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
