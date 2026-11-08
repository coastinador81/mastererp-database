CREATE TABLE onboarding_setup_states (
 user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
 version integer NOT NULL DEFAULT 1,
 first_intent text NOT NULL DEFAULT '' CHECK(length(first_intent)<=4000),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON onboarding_setup_states
 FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
