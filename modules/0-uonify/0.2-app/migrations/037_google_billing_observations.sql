-- Monetary observations come from evidence in Google, never from token estimates.
CREATE TABLE google_billing_observations (
 id uuid PRIMARY KEY,
 user_id uuid NOT NULL REFERENCES users(id),
 google_subject text NOT NULL,
 project_id text NOT NULL,
 billing_account_name text NOT NULL CHECK(billing_account_name ~ '^billingAccounts/[A-Za-z0-9-]+$'),
 currency text NOT NULL CHECK(currency='EUR'),
 credit_eur numeric(24,6) CHECK(credit_eur>=0),
 consumption_eur numeric(24,6) CHECK(consumption_eur>=0),
 net_consumption_eur numeric(24,6) CHECK(net_consumption_eur>=0),
 consumption_scope text NOT NULL CHECK(consumption_scope='billing_account'),
 period_start date,
 period_end date,
 observed_at timestamptz NOT NULL,
 recorded_at timestamptz NOT NULL DEFAULT now(),
 credit_expires_at timestamptz,
 credit_expires_on date,
 credit_entries jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(credit_entries)='array'),
 source_kind text NOT NULL CHECK(source_kind='observed_google_console'),
 source_url text NOT NULL CHECK(source_url LIKE 'https://console.cloud.google.com/billing/%'),
 proof_sha256 text NOT NULL CHECK(proof_sha256 ~ '^[a-f0-9]{64}$'),
 proof_files jsonb NOT NULL CHECK(jsonb_typeof(proof_files)='array'),
 observation_sha256 text NOT NULL CHECK(observation_sha256 ~ '^[a-f0-9]{64}$'),
 CHECK(credit_eur IS NOT NULL OR consumption_eur IS NOT NULL),
 CHECK(consumption_eur IS NULL OR (period_start IS NOT NULL AND period_end IS NOT NULL)),
 CHECK(period_end IS NULL OR period_start<=period_end),
 CHECK(credit_expires_at IS NULL OR credit_expires_at>observed_at),
 CHECK(credit_expires_on IS NULL OR credit_expires_on>CAST(observed_at AT TIME ZONE 'UTC' AS date)),
 UNIQUE(user_id,google_subject,project_id,billing_account_name,observation_sha256)
);
CREATE INDEX google_billing_observations_latest ON google_billing_observations
 (user_id,google_subject,project_id,billing_account_name,observed_at DESC,recorded_at DESC);

CREATE FUNCTION immutable_google_billing_observation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 RAISE EXCEPTION 'Google billing observations are immutable';
END;
$$;
CREATE TRIGGER immutable_google_billing_observation BEFORE UPDATE OR DELETE
 ON google_billing_observations FOR EACH ROW EXECUTE FUNCTION immutable_google_billing_observation();
