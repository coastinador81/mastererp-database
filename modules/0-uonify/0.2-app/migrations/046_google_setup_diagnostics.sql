ALTER TABLE google_setup_operations ADD COLUMN error_details jsonb;
ALTER TABLE google_setup_operations ADD CONSTRAINT google_setup_error_details_object
 CHECK (error_details IS NULL OR jsonb_typeof(error_details)='object');
