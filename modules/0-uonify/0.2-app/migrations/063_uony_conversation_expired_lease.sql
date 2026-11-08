-- Recovery runs before every conversation claim. Index only running jobs and
-- put missing leases first so a crashed pre-provider job is never stranded.
-- The lease heartbeat updates this index; it does not touch historical jobs.
CREATE INDEX uony_conversation_running_lease_due
    ON uony_conversation_jobs
    ((coalesce(lease_until,'-infinity'::timestamptz)),user_id,request_id)
    WHERE status='running';
