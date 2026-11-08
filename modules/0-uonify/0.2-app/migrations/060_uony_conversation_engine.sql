-- Pin the coordinator at admission. Existing jobs stay on the classic engine;
-- changing a deployment flag cannot silently reroute queued or uncertain work.
ALTER TABLE uony_conversation_jobs
    ADD COLUMN engine text NOT NULL DEFAULT 'classic'
    CHECK (engine IN ('classic', 'adk'));
