-- Aislar conexiones históricas de pruebas sin trasladar ni borrar trabajo.
ALTER TABLE google_cloud_connections DROP CONSTRAINT google_cloud_connections_status_check;
ALTER TABLE google_cloud_connections ADD CONSTRAINT google_cloud_connections_status_check
 CHECK(status IN ('connected','reauthorize','account_mismatch'));
ALTER TABLE google_drive_connections DROP CONSTRAINT google_drive_connections_status_check;
ALTER TABLE google_drive_connections ADD CONSTRAINT google_drive_connections_status_check
 CHECK(status IN ('connected','reauthorize','account_mismatch'));
UPDATE google_cloud_connections c SET status='account_mismatch'
 FROM users u WHERE c.user_id=u.id AND c.google_subject<>u.google_subject;
UPDATE google_drive_connections c SET status='account_mismatch'
 FROM users u WHERE c.user_id=u.id AND c.google_subject<>u.google_subject;
ALTER TABLE cloud_popup_flows ADD COLUMN error_code text;
ALTER TABLE drive_popup_flows ADD COLUMN error_code text;
