-- Recovery references only. Durable work/consent remain in their own ledgers.
ALTER TABLE uony_live_sessions ADD COLUMN heartbeat_at timestamptz NOT NULL DEFAULT now();
CREATE TABLE uony_session_continuity (
 user_id uuid NOT NULL,
 thread_id text NOT NULL,
 session_id uuid NOT NULL,
 google_subject text,
 google_project_id text,
 fence bigint NOT NULL CHECK (fence > 0),
 version bigint NOT NULL CHECK (version > 0),
 active boolean NOT NULL DEFAULT true,
 snapshot jsonb NOT NULL DEFAULT '{"activeTurnId":null,"requests":[],"events":[]}',
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (user_id,thread_id),
 FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id) ON DELETE CASCADE,
 CHECK (jsonb_typeof(snapshot)='object'),
 CHECK ((google_subject IS NULL) = (google_project_id IS NULL)),
 CHECK (octet_length(snapshot::text) <= 65536)
);
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_session_continuity
 FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
