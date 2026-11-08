ALTER TABLE onboarding_setup_states
 ADD COLUMN delivery_request_id uuid,
 ADD COLUMN delivery_thread_id text,
 ADD COLUMN delivery_text text,
 ADD COLUMN delivery_model text,
 ADD COLUMN delivery_effort text,
 ADD COLUMN delivery_claimed_at timestamptz;
ALTER TABLE onboarding_setup_states ADD CONSTRAINT onboarding_delivery_complete_tuple CHECK (
 (delivery_request_id IS NULL AND delivery_thread_id IS NULL AND delivery_text IS NULL
  AND delivery_model IS NULL AND delivery_effort IS NULL AND delivery_claimed_at IS NULL)
 OR (delivery_request_id IS NOT NULL AND delivery_thread_id IS NOT NULL AND delivery_text IS NOT NULL
  AND delivery_model IS NOT NULL AND delivery_effort IS NOT NULL AND delivery_claimed_at IS NOT NULL
  AND length(delivery_text) BETWEEN 1 AND 3000)
);
CREATE UNIQUE INDEX onboarding_delivery_request ON onboarding_setup_states(delivery_request_id)
 WHERE delivery_request_id IS NOT NULL;
