CREATE TABLE google_setup_operations (
 id uuid PRIMARY KEY,
 user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 google_subject text NOT NULL,
 mode text NOT NULL CHECK(mode IN ('create','existing')),
 project_id text NOT NULL,
 project_name text NOT NULL,
 project_resource text,
 billing_account_name text,
 configuration_approved_at timestamptz NOT NULL DEFAULT now(),
 model_consented_at timestamptz,
 status text NOT NULL DEFAULT 'preparing' CHECK(status IN ('preparing','action_required','ready','unknown')),
 step text NOT NULL DEFAULT 'project',
 model_test text NOT NULL DEFAULT 'not_started' CHECK(model_test IN ('not_started','pending','passed','failed','unknown')),
 usage jsonb,
 error_code text,
 message text NOT NULL DEFAULT '',
 external_operation text,
 lease_until timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX google_setup_owner ON google_setup_operations(user_id,created_at DESC);
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON google_setup_operations
 FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
