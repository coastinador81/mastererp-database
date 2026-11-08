-- Gate 120B · Craft input namespace lease + generation journal + resumption.
--
-- INACTIVE internal contract (desired_active=false, CHECK NOT desired_active).
-- Forward-only AND idempotent (IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT),
-- so a partial retry re-applies cleanly (unlike 121). Provides the exclusive
-- namespace lease, the append-only generation journal and the resumption state
-- for the descriptor->uploader hand-off deferred by creative_craft_input_sink.py
-- and for multi-host resume. SOLELY for the Craft input sink: nothing here is
-- about Google generated-asset storage (that is Google/Interfaz's domain).
--
-- Conventions: mirrors Gate 119 role/append-only patterns and Gate 102
-- least-privilege. Reuses the existing receipt_definer_role (as Gate 119 does for
-- creative_craft_input_resume); creates no new roles. Loose coupling: hard FKs
-- only between immutable/append-only Craft tables (installation bindings, our own
-- lease). NEVER a FK toward uony_threads/uony_projects or the user deletion path
-- (the craft_consumption_present preflight guards that), so this never adds a
-- NO ACTION edge that could re-block a thread/project delete.
--
-- APPLY POLICY: additive/forward-only, inactive. Do NOT apply to the Live/ADK
-- shared DB nor bake into a Live image during AI-19 acceptance; apply sequencing
-- is owned by Interfaz. Final SQL pending Interfaz review + an independent
-- adversarial P0/P1 pass (as 118/119/120 had) before it is considered landed.

DO $preflight$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
      WHERE table_schema=current_schema()
        AND table_name='creative_craft_input_installation_bindings') THEN
    RAISE EXCEPTION 'Gate 122 requires the Gate 118 input installation binding'
      USING ERRCODE='55000';
  END IF;
END $preflight$;

-- ---------------------------------------------------------------------------
-- Own binding (contract gate122-v1), append-only.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS creative_craft_input_resume_installation_bindings (
  installation_id uuid PRIMARY KEY REFERENCES
    creative_craft_input_installation_bindings(installation_id),
  installation_key text NOT NULL UNIQUE REFERENCES
    creative_craft_input_installation_bindings(installation_key),
  database_name text NOT NULL,
  schema_name text NOT NULL,
  consumer_role text NOT NULL,
  contract_version text NOT NULL DEFAULT 'gate122-v1'
    CHECK (contract_version='gate122-v1'),
  policy jsonb NOT NULL CHECK (jsonb_typeof(policy)='object'),
  policy_sha256 text NOT NULL CHECK (policy_sha256 ~ '^[0-9a-f]{64}$'),
  desired_active boolean NOT NULL DEFAULT false CHECK (NOT desired_active),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(database_name,schema_name)
);

CREATE OR REPLACE FUNCTION creative_craft_input_resume_binding_append_only()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION 'Craft input resume binding is append-only'
    USING ERRCODE='55000';
END $$;
CREATE OR REPLACE TRIGGER creative_craft_input_resume_binding_append_only
BEFORE UPDATE OR DELETE ON creative_craft_input_resume_installation_bindings
FOR EACH ROW EXECUTE FUNCTION
  creative_craft_input_resume_binding_append_only();

DO $binding$
DECLARE source record; policy_body jsonb;
BEGIN
  SELECT i.installation_id,i.installation_key,i.database_name,i.schema_name,
         t.preparer_role INTO source
    FROM creative_craft_input_installation_bindings i
    JOIN creative_craft_transition_installation_bindings t
      USING(installation_key);
  IF source.installation_id IS NULL THEN
    RETURN;
  END IF;
  policy_body:=jsonb_build_object(
    'schemaVersion',1,'policyId','craft-input-namespace-resume-v1',
    'exclusiveNamespaceLease',true,'appendOnlyGenerationJournal',true,
    'crossHostResume',true,'singleExternalDispatch',true,
    'reopenByPathForbidden',true,'releaseIsFinal',true);
  INSERT INTO creative_craft_input_resume_installation_bindings(
    installation_id,installation_key,database_name,schema_name,consumer_role,
    policy,policy_sha256)
  VALUES(source.installation_id,source.installation_key,source.database_name,
    source.schema_name,source.preparer_role,policy_body,
    creative_craft_json_sha256(policy_body))
  ON CONFLICT (installation_id) DO NOTHING;
END $binding$;

-- ---------------------------------------------------------------------------
-- Exclusive namespace lease (Option R): one row per lease generation, immutable
-- identity, never deleted; released_at/lease_until advance monotonically. A
-- partial unique index enforces a single active holder per namespace as a
-- declarative DB invariant (not derived in code). lease_epoch is a monotonic
-- fence.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS creative_craft_input_namespace_leases (
  user_id uuid NOT NULL,
  lease_id uuid NOT NULL,
  installation_id uuid NOT NULL REFERENCES
    creative_craft_input_installation_bindings(installation_id),
  storage_domain_id uuid NOT NULL,
  population_namespace_id uuid NOT NULL,
  lease_token uuid NOT NULL,
  lease_epoch bigint NOT NULL CHECK (lease_epoch>0),
  holder_host text NOT NULL CHECK (length(holder_host) BETWEEN 1 AND 255),
  acquired_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  lease_until timestamptz NOT NULL,
  released_at timestamptz,
  PRIMARY KEY (user_id,lease_id),
  UNIQUE (user_id,population_namespace_id,lease_epoch),
  CHECK (lease_until>=acquired_at),
  CHECK (released_at IS NULL OR released_at>=acquired_at)
);
CREATE UNIQUE INDEX IF NOT EXISTS creative_craft_input_namespace_lease_active
  ON creative_craft_input_namespace_leases
     (user_id,storage_domain_id,population_namespace_id)
  WHERE released_at IS NULL;

CREATE OR REPLACE FUNCTION creative_craft_input_namespace_lease_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    -- Append-only, except the account-deletion purge (house convention, as in
    -- Gate 118/119/120): allow DELETE only while this user is being deleted.
    IF current_setting('uonify.deleting_user',true)=OLD.user_id::text THEN
      PERFORM pg_advisory_xact_lock(
        hashtextextended('uonify:account:'||OLD.user_id::text,0));
      IF EXISTS(SELECT 1 FROM users WHERE id=OLD.user_id
                 AND deletion_requested_at IS NOT NULL FOR NO KEY UPDATE) THEN
        RETURN OLD;
      END IF;
    END IF;
    RAISE EXCEPTION 'Craft namespace lease is deleted only with its account'
      USING ERRCODE='42501';
  END IF;
  IF (NEW.user_id,NEW.lease_id,NEW.installation_id,NEW.storage_domain_id,
      NEW.population_namespace_id,NEW.lease_token,NEW.lease_epoch,
      NEW.holder_host,NEW.acquired_at) IS DISTINCT FROM
     (OLD.user_id,OLD.lease_id,OLD.installation_id,OLD.storage_domain_id,
      OLD.population_namespace_id,OLD.lease_token,OLD.lease_epoch,
      OLD.holder_host,OLD.acquired_at) THEN
    RAISE EXCEPTION 'Craft namespace lease identity is immutable'
      USING ERRCODE='55000';
  END IF;
  IF OLD.released_at IS NOT NULL
     AND NEW.released_at IS DISTINCT FROM OLD.released_at THEN
    RAISE EXCEPTION 'Craft namespace lease release is final'
      USING ERRCODE='55000';
  END IF;
  IF NEW.lease_until<OLD.lease_until THEN
    RAISE EXCEPTION 'Craft namespace lease cannot be shortened'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER creative_craft_input_namespace_lease_guard
BEFORE UPDATE OR DELETE ON creative_craft_input_namespace_leases
FOR EACH ROW EXECUTE FUNCTION creative_craft_input_namespace_lease_guard();

-- ---------------------------------------------------------------------------
-- Append-only generation journal: the descriptor->uploader hand-off, bound to
-- the verified descriptor identity so a resume on another host rebinds the same
-- inode/bytes and never reopens by path nor repeats the upload.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS creative_craft_input_generation_journal (
  user_id uuid NOT NULL,
  journal_id uuid NOT NULL,
  population_namespace_id uuid NOT NULL,
  lease_id uuid NOT NULL,
  lease_epoch bigint NOT NULL CHECK (lease_epoch>0),
  generation_seq bigint NOT NULL CHECK (generation_seq>0),
  phase text NOT NULL
    CHECK (phase IN ('prepared','published','adopted','reconciled')),
  descriptor_device bigint NOT NULL CHECK (descriptor_device>=0),
  descriptor_inode bigint NOT NULL CHECK (descriptor_inode>=0),
  descriptor_byte_size bigint NOT NULL CHECK (descriptor_byte_size>=0),
  descriptor_sha256 text NOT NULL CHECK (descriptor_sha256 ~ '^[0-9a-f]{64}$'),
  storage_receipt jsonb
    CHECK (storage_receipt IS NULL OR jsonb_typeof(storage_receipt)='object'),
  holder_host text NOT NULL CHECK (length(holder_host) BETWEEN 1 AND 255),
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (user_id,journal_id),
  UNIQUE (user_id,population_namespace_id,generation_seq,phase),
  FOREIGN KEY (user_id,lease_id)
    REFERENCES creative_craft_input_namespace_leases(user_id,lease_id)
);

CREATE OR REPLACE FUNCTION creative_craft_input_generation_journal_append_only()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  -- Append-only, except the account-deletion purge (house convention): allow
  -- DELETE only while this user is being deleted. UPDATE is never allowed.
  IF TG_OP='DELETE' THEN
    IF current_setting('uonify.deleting_user',true)=OLD.user_id::text THEN
      PERFORM pg_advisory_xact_lock(
        hashtextextended('uonify:account:'||OLD.user_id::text,0));
      IF EXISTS(SELECT 1 FROM users WHERE id=OLD.user_id
                 AND deletion_requested_at IS NOT NULL FOR NO KEY UPDATE) THEN
        RETURN OLD;
      END IF;
    END IF;
    RAISE EXCEPTION 'Craft generation journal is deleted only with its account'
      USING ERRCODE='42501';
  END IF;
  RAISE EXCEPTION 'Craft generation journal is append-only'
    USING ERRCODE='55000';
END $$;
CREATE OR REPLACE TRIGGER creative_craft_input_generation_journal_append_only
BEFORE UPDATE OR DELETE ON creative_craft_input_generation_journal
FOR EACH ROW EXECUTE FUNCTION
  creative_craft_input_generation_journal_append_only();

-- ---------------------------------------------------------------------------
-- Resumption state: the minimal checkpoint another host needs. phase_rank only
-- advances; lease_epoch only advances; the single external dispatch can flip
-- false->true once and its fence is immutable once set.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS creative_craft_input_resumption_state (
  user_id uuid NOT NULL,
  population_namespace_id uuid NOT NULL,
  lease_id uuid NOT NULL,
  lease_epoch bigint NOT NULL CHECK (lease_epoch>0),
  phase text NOT NULL
    CHECK (phase IN ('prepared','published','adopted','reconciled')),
  phase_rank smallint NOT NULL CHECK (phase_rank = CASE phase
    WHEN 'prepared' THEN 0 WHEN 'published' THEN 1
    WHEN 'adopted' THEN 2 WHEN 'reconciled' THEN 3 END),
  external_dispatch_issued boolean NOT NULL DEFAULT false,
  external_dispatch_fence uuid,
  last_host text NOT NULL CHECK (length(last_host) BETWEEN 1 AND 255),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (user_id,population_namespace_id),
  FOREIGN KEY (user_id,lease_id)
    REFERENCES creative_craft_input_namespace_leases(user_id,lease_id),
  CHECK (external_dispatch_issued = (external_dispatch_fence IS NOT NULL))
);

CREATE OR REPLACE FUNCTION creative_craft_input_resumption_state_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    -- Append-only, except the account-deletion purge (house convention).
    IF current_setting('uonify.deleting_user',true)=OLD.user_id::text THEN
      PERFORM pg_advisory_xact_lock(
        hashtextextended('uonify:account:'||OLD.user_id::text,0));
      IF EXISTS(SELECT 1 FROM users WHERE id=OLD.user_id
                 AND deletion_requested_at IS NOT NULL FOR NO KEY UPDATE) THEN
        RETURN OLD;
      END IF;
    END IF;
    RAISE EXCEPTION 'Craft resumption state is deleted only with its account'
      USING ERRCODE='42501';
  END IF;
  IF NEW.population_namespace_id IS DISTINCT FROM OLD.population_namespace_id
     OR NEW.phase_rank<OLD.phase_rank OR NEW.lease_epoch<OLD.lease_epoch THEN
    RAISE EXCEPTION 'Craft resumption state only advances'
      USING ERRCODE='55000';
  END IF;
  IF OLD.external_dispatch_issued AND NOT NEW.external_dispatch_issued THEN
    RAISE EXCEPTION 'Craft external dispatch cannot be un-issued'
      USING ERRCODE='55000';
  END IF;
  IF OLD.external_dispatch_fence IS NOT NULL
     AND NEW.external_dispatch_fence IS DISTINCT FROM OLD.external_dispatch_fence
  THEN
    RAISE EXCEPTION 'Craft external dispatch fence is immutable'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER creative_craft_input_resumption_state_guard
BEFORE UPDATE OR DELETE ON creative_craft_input_resumption_state
FOR EACH ROW EXECUTE FUNCTION
  creative_craft_input_resumption_state_guard();

-- ---------------------------------------------------------------------------
-- Read-only holder derivation. SECURITY DEFINER, owned by receipt_definer_role,
-- search_path pinned in the authority block below.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION creative_craft_input_namespace_lease_holder(
  p_user_id uuid, p_namespace uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
      'leaseId',lease_id::text,'leaseToken',lease_token::text,
      'leaseEpoch',lease_epoch,'holderHost',holder_host,
      'storageDomainId',storage_domain_id::text)
    FROM creative_craft_input_namespace_leases
   WHERE user_id=p_user_id AND population_namespace_id=p_namespace
     AND released_at IS NULL
   ORDER BY lease_epoch DESC
   LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- Least-privilege (Gate 102 discipline): reuse receipt_definer_role (Gate 119
-- convention). Functions owned by it, search_path pinned, EXECUTE revoked from
-- callers; tables grant nothing to app/caller roles.
-- ---------------------------------------------------------------------------
DO $authority$
DECLARE s text:=current_schema(); binding record; caller_roles text; f record;
BEGIN
  SELECT t.preparer_role,t.ack_role,t.escrow_role,
         p.receipt_definer_role,p.launcher_verifier_role,p.storage_verifier_role,
         i.input_verifier_role INTO binding
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p USING(installation_key)
    JOIN creative_craft_input_installation_bindings i USING(installation_key);
  IF binding.receipt_definer_role IS NULL THEN
    RETURN;
  END IF;
  caller_roles:=concat_ws(',',binding.preparer_role,binding.ack_role,
    binding.escrow_role,binding.launcher_verifier_role,
    binding.storage_verifier_role,binding.input_verifier_role);

  FOR f IN SELECT pr.oid::regprocedure signature FROM pg_proc pr
    JOIN pg_namespace n ON n.oid=pr.pronamespace
   WHERE n.nspname=s AND pr.proname IN (
    'creative_craft_input_resume_binding_append_only',
    'creative_craft_input_namespace_lease_guard',
    'creative_craft_input_generation_journal_append_only',
    'creative_craft_input_resumption_state_guard',
    'creative_craft_input_namespace_lease_holder') LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.signature,
      binding.receipt_definer_role);
    EXECUTE format('ALTER FUNCTION %s SET search_path TO pg_catalog,%I,pg_temp',
      f.signature,s);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,uonify_app_runtime,'
      'uonify_creative_inspector,uonify_creative_evaluator,'
      'uonify_creative_reviewer,%s',f.signature,caller_roles);
  END LOOP;

  EXECUTE format('REVOKE ALL ON '
    '%I.creative_craft_input_resume_installation_bindings,'
    '%I.creative_craft_input_namespace_leases,'
    '%I.creative_craft_input_generation_journal,'
    '%I.creative_craft_input_resumption_state '
    'FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,'
    'uonify_creative_evaluator,uonify_creative_reviewer,%s',
    s,s,s,s,caller_roles);
  EXECUTE format('GRANT SELECT ON '
    '%I.creative_craft_input_resume_installation_bindings,'
    '%I.creative_craft_input_namespace_leases,'
    '%I.creative_craft_input_generation_journal,'
    '%I.creative_craft_input_resumption_state TO %I',
    s,s,s,s,binding.receipt_definer_role);
  EXECUTE format('GRANT INSERT ON '
    '%I.creative_craft_input_namespace_leases,'
    '%I.creative_craft_input_generation_journal,'
    '%I.creative_craft_input_resumption_state TO %I',
    s,s,s,binding.receipt_definer_role);
  EXECUTE format('GRANT UPDATE(released_at,lease_until) ON '
    '%I.creative_craft_input_namespace_leases TO %I',
    s,binding.receipt_definer_role);
  EXECUTE format('GRANT UPDATE(phase,phase_rank,external_dispatch_issued,'
    'external_dispatch_fence,last_host,updated_at) ON '
    '%I.creative_craft_input_resumption_state TO %I',
    s,binding.receipt_definer_role);
END $authority$;
