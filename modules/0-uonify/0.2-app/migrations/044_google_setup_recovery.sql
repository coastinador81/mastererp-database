ALTER TABLE google_setup_operations
 ADD COLUMN retry_of uuid REFERENCES google_setup_operations(id),
 ADD COLUMN revision_of uuid REFERENCES google_setup_operations(id),
 ADD COLUMN additional_cost_accepted_at timestamptz;
ALTER TABLE google_setup_operations ADD CONSTRAINT google_setup_recovery_kind
 CHECK (retry_of IS NULL OR revision_of IS NULL);
