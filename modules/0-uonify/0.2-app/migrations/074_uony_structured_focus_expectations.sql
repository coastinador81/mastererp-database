-- Structured chat actions bypass the conversation queue. Keep their focus
-- precondition for exact request-ID replay without granting a later focus.
CREATE TABLE uony_structured_focus_expectations (
    user_id uuid NOT NULL REFERENCES users(id),
    request_id uuid NOT NULL,
    thread_id text NOT NULL,
    google_subject text NOT NULL,
    assignment_id uuid,
    focus_version integer NOT NULL,
    PRIMARY KEY (user_id,request_id),
    FOREIGN KEY (user_id,thread_id) REFERENCES uony_threads(user_id,id),
    FOREIGN KEY (user_id,assignment_id,google_subject)
        REFERENCES uony_assignments(user_id,id,google_subject),
    CHECK ((assignment_id IS NULL AND focus_version=0)
        OR (assignment_id IS NOT NULL AND focus_version>0))
);
CREATE TRIGGER account_write_allowed
    BEFORE INSERT OR UPDATE ON uony_structured_focus_expectations
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
