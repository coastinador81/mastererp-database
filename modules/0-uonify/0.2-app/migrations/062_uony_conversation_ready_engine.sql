-- The claimer starts at due queued work and probes only its account by PK.
-- Keep engine first so a disabled coordinator's backlog is not walked when
-- only the classic coordinator (or only ADK) is enabled.
CREATE INDEX uony_conversation_queued_engine_ready
    ON uony_conversation_jobs(engine,available_at,created_at,user_id,request_id)
    WHERE status='queued';

-- When both allowed engines are active, preserve one global oldest-first
-- order without sorting every queued job across the two engine backlogs.
CREATE INDEX uony_conversation_queued_ready
    ON uony_conversation_jobs(available_at,created_at,user_id,request_id)
    WHERE status='queued';
