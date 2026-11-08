-- A confirmed deletion freezes local writes before external subscriptions close.
ALTER TABLE users ADD COLUMN deletion_requested_at timestamptz;
CREATE TABLE account_deletions (
 id uuid PRIMARY KEY,
 user_id uuid REFERENCES users(id) ON DELETE SET NULL,
 identity_hash text NOT NULL,
 receipt_hash text NOT NULL,
 status text NOT NULL CHECK(status IN ('pending','error','deleted')),
 error_code text,
 message text,
 result jsonb NOT NULL DEFAULT '{}',
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 deleted_at timestamptz
);
CREATE UNIQUE INDEX account_deletions_user ON account_deletions(user_id) WHERE user_id IS NOT NULL;
CREATE TABLE account_trial_history (
 subject_hash text PRIMARY KEY,
 trial_used boolean NOT NULL,
 deleted_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION account_write_allowed() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE owner_id uuid; deleting timestamptz;
BEGIN
 IF TG_NARGS=0 THEN
  owner_id := (to_jsonb(NEW)->>'user_id')::uuid;
 ELSE
  EXECUTE format('SELECT user_id FROM %I WHERE id=$1',TG_ARGV[0])
   INTO owner_id USING (to_jsonb(NEW)->>'job_id')::uuid;
 END IF;
 IF owner_id IS NULL THEN RETURN NEW; END IF;
 -- Only inspect the committed flag here. Some OAuth callbacks record a result
 -- in a second connection while their parent transaction owns the user lock.
 -- Mutating routes and queue claims take their explicit owner lock first;
 -- an implicit row lock here would deadlock those nested result updates.
 SELECT deletion_requested_at INTO deleting FROM users WHERE id=owner_id;
 IF deleting IS NOT NULL THEN
  RAISE EXCEPTION 'Account deletion pending' USING ERRCODE='55000';
 END IF;
 RETURN NEW;
END;
$$;
DO $$
DECLARE t record;
BEGIN
 FOR t IN SELECT table_name FROM information_schema.columns
  WHERE table_schema=current_schema() AND column_name='user_id'
   AND table_name NOT IN ('sessions','account_deletions')
 LOOP
  EXECUTE format('CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON %I
   FOR EACH ROW EXECUTE FUNCTION account_write_allowed()',t.table_name);
 END LOOP;
END;
$$;
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON product_material_sources
 FOR EACH ROW EXECUTE FUNCTION account_write_allowed('product_material_jobs');
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON product_material_fragments
 FOR EACH ROW EXECUTE FUNCTION account_write_allowed('product_material_jobs');
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON product_material_calls
 FOR EACH ROW EXECUTE FUNCTION account_write_allowed('product_material_jobs');
CREATE TRIGGER account_write_allowed BEFORE INSERT OR UPDATE ON product_reasoning_calls
 FOR EACH ROW EXECUTE FUNCTION account_write_allowed('product_reasoning_jobs');

-- Observations remain immutable during ordinary work. Their owner's explicit
-- account deletion is the sole removal path; no update exemption exists.
CREATE OR REPLACE FUNCTION immutable_google_billing_observation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' AND current_setting('uonify.deleting_user',true)=OLD.user_id::text
  AND EXISTS(SELECT 1 FROM users WHERE id=OLD.user_id AND deletion_requested_at IS NOT NULL) THEN
  RETURN OLD;
 END IF;
 RAISE EXCEPTION 'Google billing observations are immutable';
END;
$$;
