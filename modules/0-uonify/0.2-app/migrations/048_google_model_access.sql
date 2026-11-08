ALTER TABLE google_setup_operations ADD COLUMN access_check jsonb;
ALTER TABLE google_setup_operations ADD CONSTRAINT google_setup_access_check_object
 CHECK (access_check IS NULL OR jsonb_typeof(access_check)='object');
