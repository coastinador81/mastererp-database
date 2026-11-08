ALTER TABLE billing_checkouts ADD COLUMN client_error_details jsonb;
ALTER TABLE billing_checkouts ADD COLUMN client_error_at timestamptz;
ALTER TABLE billing_checkouts ADD CONSTRAINT billing_checkout_client_error_object
 CHECK (client_error_details IS NULL OR jsonb_typeof(client_error_details)='object');
