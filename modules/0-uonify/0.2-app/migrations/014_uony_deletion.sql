ALTER TABLE uony_projects ADD COLUMN deleted_at timestamptz;
ALTER TABLE uony_threads ADD COLUMN deleted_at timestamptz;
