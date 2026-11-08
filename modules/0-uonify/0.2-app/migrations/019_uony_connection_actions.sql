ALTER TABLE uony_requests ADD COLUMN connection_actions jsonb NOT NULL DEFAULT '[]';
ALTER TABLE uony_requests ADD CONSTRAINT uony_connection_actions_allowed
    CHECK (connection_actions IN ('[]'::jsonb, '[{"provider":"amazon","action":"manage"}]'::jsonb));
