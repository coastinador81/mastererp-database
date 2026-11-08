-- Foco de Drive del hilo («Consultor google», 21-10-2026): a written order that
-- refers to a folder or a file of an earlier written order of the same thread
-- («allí», «esa», «la otra») gets a scope on the id the server emitted then;
-- the model writes no name. Its own source keeps that provenance auditable.
ALTER TABLE uony_drive_scopes DROP CONSTRAINT IF EXISTS uony_drive_scopes_source_check;
ALTER TABLE uony_drive_scopes ADD CONSTRAINT uony_drive_scopes_source_check
    CHECK (source IN ('voice_call','text_agent','text_focus','text_confirmed','server_metadata'));
-- The focus looks back 24 h over one account's scopes.
CREATE INDEX IF NOT EXISTS uony_drive_scopes_recent ON uony_drive_scopes (user_id, created_at DESC);
-- QA-04: the turn read document content (saved with its reply). In the next
-- turn a focus read is only for that same resource: never a proposal that a
-- document could have induced.
ALTER TABLE uony_drive_scopes ADD COLUMN IF NOT EXISTS content_read_at timestamptz;
-- A focus never raises its operation: reading one that was only listed asks the
-- customer first. The question is the server's own fixed text, and the mark is
-- usable only once it was delivered in the thread (delivered_at, saved with the
-- reply): answered only by the next written message, once, within 10 minutes.
CREATE TABLE IF NOT EXISTS uony_drive_pending_reads (
    user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    thread_id text NOT NULL,
    target_kind text NOT NULL CHECK (target_kind IN ('folder','file')),
    target_id text NOT NULL CHECK (target_id ~ '^[A-Za-z0-9_-]{1,200}$'),
    drive_id text CHECK (drive_id ~ '^[A-Za-z0-9_-]{1,200}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    delivered_at timestamptz,
    consumed_by uuid,
    consumed_at timestamptz,
    PRIMARY KEY (user_id, request_id),
    FOREIGN KEY (user_id, request_id) REFERENCES uony_requests(user_id, request_id) ON DELETE CASCADE,
    CHECK ((consumed_by IS NULL) = (consumed_at IS NULL)),
    CHECK (consumed_at IS NULL OR delivered_at IS NOT NULL),
    CHECK (expires_at > created_at)
);
DROP TRIGGER IF EXISTS account_write_allowed ON uony_drive_pending_reads;
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON uony_drive_pending_reads
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
