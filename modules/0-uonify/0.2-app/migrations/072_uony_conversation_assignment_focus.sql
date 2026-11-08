-- A queued conversation keeps the goal selected when the customer sent it.
-- Existing jobs stay unpinned and receive no goal context during rollout.
ALTER TABLE uony_conversation_jobs
    ADD COLUMN assignment_focus_pinned boolean NOT NULL DEFAULT false,
    ADD COLUMN assignment_focus_id uuid,
    ADD COLUMN assignment_focus_version integer;

ALTER TABLE uony_conversation_jobs
    ADD CONSTRAINT uony_conversation_assignment_focus_shape CHECK (
        (NOT assignment_focus_pinned AND assignment_focus_id IS NULL
            AND assignment_focus_version IS NULL)
        OR (assignment_focus_pinned AND assignment_focus_version IS NOT NULL
            AND ((assignment_focus_id IS NULL AND assignment_focus_version=0)
                OR (assignment_focus_id IS NOT NULL AND assignment_focus_version>0)))
    );
