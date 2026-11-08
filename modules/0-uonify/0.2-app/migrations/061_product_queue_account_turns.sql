-- Persist the last claim for each account so a single worker cannot drain one
-- account's old backlog while another account is waiting. The user row is
-- already the account-level claim barrier and is removed on account deletion.
ALTER TABLE users ADD COLUMN materials_last_claim_at timestamptz;
ALTER TABLE users ADD COLUMN reasoning_last_claim_at timestamptz;

-- Each claim reads only the account's first eligible job and running barrier.
CREATE INDEX product_material_jobs_queued_account
    ON product_material_jobs(user_id,updated_at,created_at,id) WHERE status='queued';
CREATE INDEX product_material_jobs_running_account
    ON product_material_jobs(user_id) WHERE status='running';
CREATE INDEX product_reasoning_jobs_queued_account
    ON product_reasoning_jobs(user_id,updated_at,created_at,id) WHERE status='queued';
CREATE INDEX product_reasoning_jobs_running_account
    ON product_reasoning_jobs(user_id) WHERE status='running';
