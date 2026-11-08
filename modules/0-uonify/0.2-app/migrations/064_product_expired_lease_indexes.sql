-- Recovery polls only running jobs. Missing leases are due first; completed
-- history is excluded. Apply in a maintenance window on large live tables.
CREATE INDEX product_material_jobs_running_lease_due
    ON product_material_jobs
    ((coalesce(lease_until,'-infinity'::timestamptz)),user_id,id)
    WHERE status='running';
CREATE INDEX product_reasoning_jobs_running_lease_due
    ON product_reasoning_jobs
    ((coalesce(lease_until,'-infinity'::timestamptz)),user_id,id)
    WHERE status='running';
