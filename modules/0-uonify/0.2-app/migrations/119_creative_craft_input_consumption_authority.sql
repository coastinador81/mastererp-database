-- Forward-only, inactive Craft input consumption authority.
--
-- Gate 119 consumes one Gate 118 attestation and records provider start in the
-- same transaction.  It also fences cancellation of attached populations and
-- reconciles that cancellation only from a physically consumed cleanup
-- receipt.  No route, worker, provider, GCS, startup, UI, voice, or Live path
-- is connected by this migration; desired_active remains false.

SELECT pg_advisory_xact_lock(
  hashtextextended('uonify-craft-launcher-roles-v1',0));
SELECT pg_advisory_xact_lock(
  hashtextextended('uonify-craft-transition-api-v1',0));
SELECT pg_advisory_xact_lock(
  hashtextextended('uonify-craft-transition-api-v2',0));
SELECT pg_advisory_xact_lock(
  hashtextextended('uonify-craft-physical-api-v1',0));
SELECT pg_advisory_xact_lock(
  hashtextextended('uonify-craft-materialization-v1',0));
SELECT pg_advisory_xact_lock(
  hashtextextended('uonify-craft-materialization-v2',0));
SELECT pg_advisory_xact_lock(
  hashtextextended('uonify-craft-input-authority-v1',0));
SELECT pg_advisory_xact_lock(
  hashtextextended('uonify-craft-input-consumption-v1',0));

DO $preflight$
DECLARE binding record; role_name text; relation_name text; database_oid oid;
BEGIN
  IF to_regclass('creative_craft_input_installation_bindings') IS NULL
     OR to_regprocedure(
       'creative_craft_input_mint(uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb)')
        IS NULL
     OR to_regclass(
       'creative_craft_input_consumption_installation_bindings') IS NOT NULL
  THEN
    RAISE EXCEPTION 'Craft 119 requires one clean 118 installation'
      USING ERRCODE='55000';
  END IF;
  SELECT i.*,t.preparer_role,t.ack_role,t.escrow_role,
         p.launcher_verifier_role,p.storage_verifier_role,
         p.receipt_definer_role,p.completion_definer_role
    INTO binding
    FROM creative_craft_input_installation_bindings i
    JOIN creative_craft_transition_installation_bindings t
      USING(installation_key)
    JOIN creative_craft_physical_installation_bindings p
      USING(installation_key)
   WHERE i.database_name=current_database()
     AND i.schema_name=current_schema();
  IF binding.installation_id IS NULL OR binding.desired_active THEN
    RAISE EXCEPTION 'Craft 119 requires one inactive scoped installation'
      USING ERRCODE='55000';
  END IF;
  SELECT oid INTO database_oid FROM pg_database
   WHERE datname=current_database();
  FOREACH role_name IN ARRAY ARRAY[
      binding.preparer_role,binding.ack_role,binding.escrow_role,
      binding.launcher_verifier_role,binding.storage_verifier_role,
      binding.receipt_definer_role,binding.completion_definer_role,
      binding.input_verifier_role] LOOP
    IF EXISTS(SELECT 1 FROM pg_roles role_row
       WHERE role_row.rolname=role_name AND (
         role_row.rolcanlogin OR role_row.rolinherit OR role_row.rolsuper
         OR role_row.rolcreatedb OR role_row.rolcreaterole
         OR role_row.rolreplication OR role_row.rolbypassrls
         OR EXISTS(SELECT 1 FROM pg_auth_members membership
              WHERE membership.roleid=role_row.oid
                 OR membership.member=role_row.oid)
         OR EXISTS(SELECT 1 FROM pg_shdepend dependency
              WHERE dependency.refclassid='pg_authid'::regclass
                AND dependency.refobjid=role_row.oid
                AND (dependency.dbid<>database_oid
                  OR dependency.deptype NOT IN ('a','o')
                  OR CASE dependency.classid
                    WHEN 'pg_namespace'::regclass THEN NOT EXISTS(
                      SELECT 1 FROM pg_namespace namespace
                       WHERE namespace.oid=dependency.objid
                         AND namespace.nspname=current_schema())
                    WHEN 'pg_proc'::regclass THEN NOT EXISTS(
                      SELECT 1 FROM pg_proc procedure
                      JOIN pg_namespace namespace
                        ON namespace.oid=procedure.pronamespace
                       WHERE procedure.oid=dependency.objid
                         AND namespace.nspname=current_schema()
                         AND procedure.proname LIKE 'creative_craft_%')
                    WHEN 'pg_class'::regclass THEN NOT EXISTS(
                      SELECT 1 FROM pg_class relation
                      JOIN pg_namespace namespace
                        ON namespace.oid=relation.relnamespace
                       WHERE relation.oid=dependency.objid
                         AND namespace.nspname=current_schema()
                         AND (relation.relname LIKE 'creative_craft_%'
                           OR relation.relname IN (
                             'users','creative_execution_jobs',
                             'creative_execution_steps',
                             'creative_execution_attempts',
                             'creative_execution_admissions',
                             'creative_assets','creative_asset_revisions',
                             'creative_runtime_reconciliation_outbox',
                             'creative_candidate_receipts',
                             'creative_candidate_states',
                             'creative_candidate_quarantines',
                             'creative_candidate_quarantine_assets',
                             'creative_candidate_native_projects',
                             'creative_native_project_revisions')))
                    ELSE true END)))) THEN
      RAISE EXCEPTION 'Craft 119 scoped role is contaminated: %',role_name
        USING ERRCODE='55000';
    END IF;
  END LOOP;
  FOREACH role_name IN ARRAY ARRAY[
      binding.preparer_role,binding.ack_role,binding.escrow_role,
      binding.launcher_verifier_role,binding.storage_verifier_role,
      binding.input_verifier_role] LOOP
    FOREACH relation_name IN ARRAY ARRAY[
      'users','creative_execution_jobs','creative_execution_steps',
      'creative_execution_attempts','creative_execution_admissions',
      'creative_execution_approvals','creative_execution_quotes',
      'uony_creative_plans','uony_threads','google_cloud_connections',
      'creative_assets','creative_asset_revisions',
      'creative_craft_launcher_reservations',
      'creative_craft_physical_challenges','creative_craft_physical_receipts',
      'creative_craft_physical_receipt_consumptions',
      'creative_craft_materialization_intents',
      'creative_craft_materialization_populations',
      'creative_craft_input_installation_bindings',
      'creative_craft_input_manifests','creative_craft_input_mints',
      'creative_craft_input_cancellations'] LOOP
      IF to_regclass(format('%I.%I',current_schema(),relation_name)) IS NOT NULL
         AND (has_table_privilege(role_name,
           format('%I.%I',current_schema(),relation_name),
           'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         OR has_any_column_privilege(role_name,
           format('%I.%I',current_schema(),relation_name),
           'SELECT,INSERT,UPDATE,REFERENCES')) THEN
        RAISE EXCEPTION 'Craft 119 caller gained direct table access before install: % on %',
          role_name,relation_name USING ERRCODE='55000';
      END IF;
      IF EXISTS(SELECT 1 FROM pg_class relation
          JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
          JOIN pg_roles owner_role ON owner_role.oid=relation.relowner
         WHERE namespace.nspname=current_schema()
           AND relation.relname=relation_name
           AND owner_role.rolname=role_name) THEN
        RAISE EXCEPTION 'Craft 119 caller owns sensitive relation before install: % on %',
          role_name,relation_name USING ERRCODE='55000';
      END IF;
    END LOOP;
  END LOOP;
  IF EXISTS(SELECT 1 FROM creative_craft_input_manifests manifest
      JOIN creative_execution_attempts attempt
        ON attempt.user_id=manifest.user_id AND attempt.id=manifest.attempt_id
     WHERE attempt.provider_started_at IS NOT NULL)
     OR EXISTS(SELECT 1 FROM creative_craft_input_cancellations cancellation
      JOIN creative_craft_materialization_populations population
        ON population.user_id=cancellation.user_id
       AND population.intent_id=cancellation.intent_id
     WHERE population.attached_at IS NOT NULL
       AND (cancellation.population_generation_id IS NULL
            OR cancellation.state='completed')) THEN
    RAISE EXCEPTION 'Craft 119 refuses unproven legacy input state'
      USING ERRCODE='55000';
  END IF;
END $preflight$;

CREATE TABLE creative_craft_input_consumption_installation_bindings (
  installation_id uuid PRIMARY KEY REFERENCES
    creative_craft_input_installation_bindings(installation_id),
  installation_key text NOT NULL UNIQUE REFERENCES
    creative_craft_input_installation_bindings(installation_key),
  database_name text NOT NULL,
  schema_name text NOT NULL,
  consumer_role text NOT NULL,
  contract_version text NOT NULL DEFAULT 'gate119-v1'
    CHECK (contract_version='gate119-v1'),
  policy jsonb NOT NULL CHECK (jsonb_typeof(policy)='object'),
  policy_sha256 text NOT NULL CHECK (policy_sha256 ~ '^[0-9a-f]{64}$'),
  desired_active boolean NOT NULL DEFAULT false CHECK (NOT desired_active),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(database_name,schema_name)
);

CREATE FUNCTION creative_craft_input_consumption_binding_append_only()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION 'Craft input consumption binding is append-only'
    USING ERRCODE='55000';
END $$;
CREATE TRIGGER creative_craft_input_consumption_binding_append_only
BEFORE UPDATE OR DELETE
ON creative_craft_input_consumption_installation_bindings
FOR EACH ROW EXECUTE FUNCTION
  creative_craft_input_consumption_binding_append_only();

DO $binding$
DECLARE source record; policy_body jsonb;
BEGIN
  SELECT i.installation_id,i.installation_key,i.database_name,i.schema_name,
         t.preparer_role INTO source
    FROM creative_craft_input_installation_bindings i
    JOIN creative_craft_transition_installation_bindings t
      USING(installation_key);
  policy_body:=jsonb_build_object(
    'schemaVersion',1,'policyId','craft-input-consumption-v1',
    'atomicProviderStart',true,'firstResponseAuthorizesDispatch',true,
    'replayAuthorizesDispatch',false,'crossHostResume',true,
    'revalidateCancellation',true,'revalidateAssets',true,
    'physicalCleanupReceiptRequiredForAttachedCancellation',true);
  INSERT INTO creative_craft_input_consumption_installation_bindings(
    installation_id,installation_key,database_name,schema_name,consumer_role,
    policy,policy_sha256)
  VALUES(source.installation_id,source.installation_key,source.database_name,
    source.schema_name,source.preparer_role,policy_body,
    creative_craft_json_sha256(policy_body));
END $binding$;

CREATE TABLE creative_craft_input_attestation_consumptions (
  user_id uuid NOT NULL,
  consumption_id uuid NOT NULL,
  mint_id uuid NOT NULL,
  attempt_id uuid NOT NULL,
  intent_id uuid NOT NULL,
  population_generation_id uuid NOT NULL,
  installation_id uuid NOT NULL,
  storage_domain_id uuid NOT NULL,
  job_id uuid NOT NULL,
  step_id uuid NOT NULL,
  attempt_no integer NOT NULL CHECK (attempt_no>0),
  claim_lease_token uuid NOT NULL,
  fence_epoch bigint NOT NULL CHECK (fence_epoch>0),
  admission_sha256 text NOT NULL CHECK (admission_sha256 ~ '^[0-9a-f]{64}$'),
  claim_set_sha256 text NOT NULL CHECK (claim_set_sha256 ~ '^[0-9a-f]{64}$'),
  dispatch_id uuid NOT NULL,
  request_sha256 text NOT NULL CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
  plan_sha256 text NOT NULL CHECK (plan_sha256 ~ '^[0-9a-f]{64}$'),
  population_fence_sha256 text NOT NULL
    CHECK (population_fence_sha256 ~ '^[0-9a-f]{64}$'),
  manifest_sha256 text NOT NULL CHECK (manifest_sha256 ~ '^[0-9a-f]{64}$'),
  verified_input_set_sha256 text NOT NULL
    CHECK (verified_input_set_sha256 ~ '^[0-9a-f]{64}$'),
  populate_receipt_sha256 text NOT NULL
    CHECK (populate_receipt_sha256 ~ '^[0-9a-f]{64}$'),
  attestation_sha256 text NOT NULL
    CHECK (attestation_sha256 ~ '^[0-9a-f]{64}$'),
  provider_started_at timestamptz NOT NULL,
  receipt jsonb NOT NULL CHECK (jsonb_typeof(receipt)='object'),
  receipt_sha256 text NOT NULL CHECK (receipt_sha256 ~ '^[0-9a-f]{64}$'),
  consumed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(user_id,mint_id),
  UNIQUE(consumption_id),
  UNIQUE(user_id,attempt_id),
  UNIQUE(user_id,population_generation_id),
  FOREIGN KEY(user_id,mint_id)
    REFERENCES creative_craft_input_mints(user_id,mint_id),
  FOREIGN KEY(user_id,population_generation_id)
    REFERENCES creative_craft_input_mints(user_id,population_generation_id),
  FOREIGN KEY(user_id,intent_id,attempt_id,population_generation_id)
    REFERENCES creative_craft_materialization_populations
      (user_id,intent_id,attempt_id,population_generation_id),
  FOREIGN KEY(installation_id)
    REFERENCES creative_craft_input_consumption_installation_bindings(
      installation_id)
);

CREATE TABLE creative_craft_input_cancellation_completions (
  user_id uuid NOT NULL,
  intent_id uuid NOT NULL,
  request_id uuid NOT NULL,
  population_generation_id uuid NOT NULL,
  cleanup_receipt_id uuid NOT NULL,
  cleanup_receipt_sha256 text NOT NULL
    CHECK (cleanup_receipt_sha256 ~ '^[0-9a-f]{64}$'),
  completion jsonb NOT NULL CHECK (jsonb_typeof(completion)='object'),
  completion_sha256 text NOT NULL
    CHECK (completion_sha256 ~ '^[0-9a-f]{64}$'),
  completed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(user_id,intent_id),
  UNIQUE(request_id),
  UNIQUE(user_id,population_generation_id),
  FOREIGN KEY(user_id,intent_id)
    REFERENCES creative_craft_input_cancellations(user_id,intent_id),
  FOREIGN KEY(user_id,population_generation_id)
    REFERENCES creative_craft_materialization_populations(
      user_id,population_generation_id),
  FOREIGN KEY(user_id,cleanup_receipt_id)
    REFERENCES creative_craft_physical_receipts(user_id,receipt_id)
);

CREATE FUNCTION creative_craft_input_consumption_ledger_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE completion_owner text;
BEGIN
  IF TG_OP='DELETE' THEN
    IF current_setting('uonify.deleting_user',true)=OLD.user_id::text THEN
      PERFORM pg_advisory_xact_lock(
        hashtextextended('uonify:account:'||OLD.user_id::text,0));
      IF EXISTS(SELECT 1 FROM users WHERE id=OLD.user_id
                 AND deletion_requested_at IS NOT NULL FOR NO KEY UPDATE) THEN
        RETURN OLD;
      END IF;
    END IF;
    RAISE EXCEPTION 'Craft input consumption is deleted only with its account'
      USING ERRCODE='42501';
  END IF;
  SELECT completion_definer_role INTO completion_owner
    FROM creative_craft_physical_installation_bindings;
  IF current_user<>completion_owner THEN
    RAISE EXCEPTION 'Craft input consumption requires scoped authority'
      USING ERRCODE='42501';
  END IF;
  IF TG_OP='UPDATE' THEN
    RAISE EXCEPTION 'Craft input consumption evidence is append-only'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER creative_craft_input_attestation_consumption_guard
BEFORE INSERT OR UPDATE OR DELETE
ON creative_craft_input_attestation_consumptions
FOR EACH ROW EXECUTE FUNCTION creative_craft_input_consumption_ledger_guard();
CREATE TRIGGER creative_craft_input_cancellation_completion_guard
BEFORE INSERT OR UPDATE OR DELETE
ON creative_craft_input_cancellation_completions
FOR EACH ROW EXECUTE FUNCTION creative_craft_input_consumption_ledger_guard();

CREATE FUNCTION creative_craft_input_resume(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_generation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; population record; manifest_row record; mint_row record;
        consumed record;
BEGIN
  PERFORM creative_craft_input_require_verifier();
  IF p_user_id IS NULL OR p_attempt_id IS NULL OR p_intent_id IS NULL
     OR p_generation_id IS NULL THEN
    RAISE EXCEPTION 'Craft input resume identity is not closed'
      USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT * INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR owner_row.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(
    creative_craft_attempt_advisory_key(p_attempt_id));
  IF EXISTS(SELECT 1 FROM creative_craft_input_cancellations c
             WHERE c.user_id=p_user_id AND c.intent_id=p_intent_id) THEN
    RETURN jsonb_build_object('status','cancelled','dispatchAuthorized',false);
  END IF;
  SELECT * INTO population FROM creative_craft_materialization_populations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id
     AND intent_id=p_intent_id
     AND population_generation_id=p_generation_id FOR UPDATE;
  IF population.state='forgotten' THEN
    RETURN jsonb_build_object('status','forgotten','dispatchAuthorized',false);
  ELSIF population.state IN
      ('cleanup_required','cleanup_running','cleanup_committed') THEN
    RETURN jsonb_build_object('status','cleanup_required',
      'dispatchAuthorized',false);
  END IF;
  SELECT * INTO manifest_row FROM creative_craft_input_manifests
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id
     AND intent_id=p_intent_id
     AND population_generation_id=p_generation_id FOR UPDATE;
  IF manifest_row.mint_id IS NULL
     OR NOT creative_craft_input_assets_current(p_user_id,manifest_row.manifest)
  THEN RETURN NULL; END IF;
  SELECT * INTO mint_row FROM creative_craft_input_mints
   WHERE user_id=p_user_id AND mint_id=manifest_row.mint_id FOR UPDATE;
  SELECT * INTO consumed FROM creative_craft_input_attestation_consumptions
   WHERE user_id=p_user_id AND mint_id=manifest_row.mint_id;
  IF consumed.consumption_id IS NOT NULL THEN
    RETURN jsonb_build_object('status','consumed','dispatchAuthorized',false,
      'mintId',manifest_row.mint_id::text,
      'consumptionId',consumed.consumption_id::text,
      'receipt',consumed.receipt,'receiptSha256',consumed.receipt_sha256);
  ELSIF mint_row.mint_id IS NULL THEN
    IF population.state='writing'
       AND population.writer_token=manifest_row.writer_token
       AND population.writer_lease_until>clock_timestamp()
       AND clock_timestamp()<population.created_at+interval '15 minutes' THEN
      RETURN jsonb_build_object('status','registered','dispatchAuthorized',false,
        'mintId',manifest_row.mint_id::text,
        'writerToken',manifest_row.writer_token::text,
        'manifest',manifest_row.manifest,
        'manifestRuntimeSha256',manifest_row.manifest_runtime_sha256);
    END IF;
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('status','minted','dispatchAuthorized',false,
    'mintId',manifest_row.mint_id::text,
    'writerToken',manifest_row.writer_token::text,
    'manifest',manifest_row.manifest,
    'manifestRuntimeSha256',manifest_row.manifest_runtime_sha256,
    'verifiedInputSet',mint_row.verified_input_set,
    'populateReceipt',mint_row.populate_receipt,
    'attestation',mint_row.attestation);
END $$;

CREATE FUNCTION creative_craft_input_consume_and_provider_start(
  p_user_id uuid,p_attempt_id uuid,p_claim_lease_token uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; admission_row record; intent_row record;
        population record; reservation record; manifest_row record;
        mint_row record; existing record; binding record; approval_row record;
        quote_row record; plan_row record; thread_row record; cloud_row record;
        newest_plan uuid;
        started timestamptz; consumption uuid; receipt_body jsonb;
        receipt_hash text; claim_token_hash text;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  IF p_user_id IS NULL OR p_attempt_id IS NULL OR p_claim_lease_token IS NULL THEN
    RAISE EXCEPTION 'Craft input consumption identity is not closed'
      USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT * INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR owner_row.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(
    creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT job_id,step_id INTO seed FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO job_row FROM creative_execution_jobs
   WHERE user_id=p_user_id AND id=seed.job_id FOR UPDATE;
  SELECT * INTO step_row FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=seed.job_id AND step_id=seed.step_id
   FOR UPDATE;
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO admission_row FROM creative_execution_admissions
   WHERE user_id=p_user_id AND job_id=seed.job_id FOR SHARE;
  SELECT * INTO existing FROM creative_craft_input_attestation_consumptions
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  IF existing.consumption_id IS NOT NULL THEN
    IF existing.claim_lease_token<>p_claim_lease_token THEN
      RAISE EXCEPTION 'Craft input consumption retry diverged'
        USING ERRCODE='40001';
    END IF;
    RETURN jsonb_build_object('status','unknown','dispatchAuthorized',false,
      'consumptionId',existing.consumption_id::text,
      'mintId',existing.mint_id::text,'receipt',existing.receipt,
      'receiptSha256',existing.receipt_sha256);
  END IF;
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT * INTO population FROM creative_craft_materialization_populations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id
     AND intent_id=intent_row.intent_id AND state='attached' FOR UPDATE;
  SELECT * INTO reservation FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  IF EXISTS(SELECT 1 FROM creative_craft_input_cancellations cancellation
             WHERE cancellation.user_id=p_user_id
               AND cancellation.intent_id=intent_row.intent_id) THEN
    RETURN NULL;
  END IF;
  SELECT * INTO manifest_row FROM creative_craft_input_manifests
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id
     AND intent_id=intent_row.intent_id
     AND population_generation_id=population.population_generation_id
   FOR UPDATE;
  SELECT * INTO mint_row FROM creative_craft_input_mints
   WHERE user_id=p_user_id AND mint_id=manifest_row.mint_id
     AND population_generation_id=population.population_generation_id
   FOR UPDATE;
  SELECT c.*,p.storage_domain_id INTO binding
    FROM creative_craft_input_consumption_installation_bindings c
    JOIN creative_craft_physical_installation_bindings p
      USING(installation_id);
  SELECT * INTO approval_row FROM creative_execution_approvals
   WHERE user_id=p_user_id AND id=job_row.approval_id FOR SHARE;
  SELECT * INTO quote_row FROM creative_execution_quotes
   WHERE user_id=p_user_id AND id=approval_row.quote_id FOR SHARE;
  SELECT * INTO plan_row FROM uony_creative_plans
   WHERE user_id=p_user_id AND id=quote_row.plan_id FOR SHARE;
  SELECT * INTO thread_row FROM uony_threads
   WHERE user_id=p_user_id AND id=quote_row.thread_id FOR SHARE;
  SELECT * INTO cloud_row FROM google_cloud_connections
   WHERE user_id=p_user_id FOR SHARE;
  SELECT id INTO newest_plan FROM uony_creative_plans
   WHERE user_id=p_user_id AND thread_id=quote_row.thread_id
   ORDER BY created_at DESC,id DESC LIMIT 1;
  IF population.population_generation_id IS NULL OR mint_row.mint_id IS NULL
     OR binding.desired_active
     OR job_row.status<>'running' OR step_row.status<>'running'
     OR attempt_row.status<>'running' OR step_row.kind<>'craft'
     OR NOT step_row.provider_call
     OR job_row.lease_until<=clock_timestamp()
     OR step_row.lease_until<=clock_timestamp()
     OR attempt_row.lease_until<=clock_timestamp()
     OR job_row.lease_token<>attempt_row.lease_token
     OR step_row.lease_token<>attempt_row.lease_token
     OR attempt_row.claim_lease_token<>p_claim_lease_token
     OR attempt_row.claim_lease_token<>intent_row.claim_lease_token
     OR attempt_row.fence_epoch<>intent_row.fence_epoch
     OR attempt_row.admission_sha256<>admission_row.admission_sha256
     OR attempt_row.claim_set_sha256<>admission_row.input_claim_set_sha256
     OR attempt_row.admission_id<>admission_row.id
     OR admission_row.expires_at<=clock_timestamp()
     OR approval_row.id IS NULL OR quote_row.id IS NULL OR plan_row.id IS NULL
     OR thread_row.id IS NULL OR cloud_row.user_id IS NULL
     OR owner_row.deletion_requested_at IS NOT NULL
     OR owner_row.google_subject IS DISTINCT FROM quote_row.google_subject
     OR plan_row.google_subject IS DISTINCT FROM owner_row.google_subject
     OR cloud_row.google_subject IS DISTINCT FROM owner_row.google_subject
     OR plan_row.status IS DISTINCT FROM 'draft'
     OR thread_row.deleted_at IS NOT NULL
     OR plan_row.revision IS DISTINCT FROM quote_row.plan_revision
     OR plan_row.thread_id IS DISTINCT FROM quote_row.thread_id
     OR newest_plan IS DISTINCT FROM plan_row.id
     OR cloud_row.project_id IS DISTINCT FROM quote_row.google_project_id
     OR cloud_row.project_id IS DISTINCT FROM plan_row.project_id
     OR cloud_row.status IS DISTINCT FROM 'connected'
     OR jsonb_typeof(cloud_row.project_check) IS DISTINCT FROM 'object'
     OR cloud_row.project_check->>'ready' IS DISTINCT FROM 'true'
     OR cloud_row.project_check->>'billing' IS DISTINCT FROM 'enabled'
     OR approval_row.quote_sha256 IS DISTINCT FROM quote_row.quote_sha256
     OR approval_row.binding_sha256 IS DISTINCT FROM quote_row.binding_sha256
     OR approval_row.costs_snapshot_sha256 IS DISTINCT FROM
          quote_row.costs_snapshot_sha256
     OR approval_row.max_total_usd IS DISTINCT FROM quote_row.max_total_usd
     OR admission_row.execution_graph_sha256 IS DISTINCT FROM
          job_row.execution_graph_sha256
     OR admission_row.quote_sha256 IS DISTINCT FROM quote_row.quote_sha256
     OR admission_row.binding_sha256 IS DISTINCT FROM quote_row.binding_sha256
     OR admission_row.costs_snapshot_sha256 IS DISTINCT FROM
          quote_row.costs_snapshot_sha256
     OR quote_row.quote_sha256 IS DISTINCT FROM
          creative_craft_json_sha256(quote_row.quote_snapshot)
     OR quote_row.source_plan_sha256 IS DISTINCT FROM
          creative_craft_json_sha256(quote_row.source_plan_snapshot)
     OR quote_row.execution_snapshot_sha256 IS DISTINCT FROM
          creative_craft_json_sha256(quote_row.execution_snapshot)
     OR quote_row.edit_recipe_sha256 IS DISTINCT FROM
          creative_craft_json_sha256(quote_row.edit_recipe)
     OR quote_row.input_manifest_sha256 IS DISTINCT FROM
          creative_craft_json_sha256(quote_row.input_manifest)
     OR quote_row.limits_sha256 IS DISTINCT FROM
          creative_craft_json_sha256(quote_row.limits_snapshot)
     OR job_row.execution_graph_sha256 IS DISTINCT FROM
          creative_craft_json_sha256(job_row.graph_snapshot)
     OR job_row.graph_snapshot->>'approvalId' IS DISTINCT FROM
          approval_row.id::text
     OR job_row.graph_snapshot->>'quoteSha256' IS DISTINCT FROM
          quote_row.quote_sha256
     OR job_row.graph_snapshot->>'bindingSha256' IS DISTINCT FROM
          quote_row.binding_sha256
     OR job_row.graph_snapshot->>'costsSnapshotSha256' IS DISTINCT FROM
          quote_row.costs_snapshot_sha256
     OR EXISTS(SELECT 1
          FROM jsonb_array_elements(manifest_row.manifest->'entries') entry
          LEFT JOIN creative_assets scoped_asset
            ON scoped_asset.user_id=p_user_id
           AND scoped_asset.id=(entry->>'assetId')::uuid
         WHERE scoped_asset.id IS NULL
            OR scoped_asset.uonify_project_id IS DISTINCT FROM
                 quote_row.uonify_project_id)
     OR attempt_row.craft_authority_bound_at IS NULL
     OR attempt_row.craft_resolved_input_manifest_sha256<>
          manifest_row.input_manifest_sha256
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR step_row.provider_started_at IS NOT NULL
     OR step_row.provider_returned_at IS NOT NULL
     OR intent_row.state<>'attached' OR population.state<>'attached'
     OR population.installation_id<>binding.installation_id
     OR population.storage_domain_id<>binding.storage_domain_id
     OR reservation.materialization_intent_id<>intent_row.intent_id
     OR reservation.materialization_generation_id<>
          population.population_generation_id
     OR reservation.storage_domain_id<>population.storage_domain_id
     OR reservation.compensation_status<>'confirmed'
     OR reservation.reserved_at IS NULL
     OR reservation.dispatch_id::text IS DISTINCT FROM
          manifest_row.manifest->>'dispatchId'
     OR reservation.request_sha256 IS DISTINCT FROM
          manifest_row.manifest->>'requestSha256'
     OR population.plan_sha256<>manifest_row.plan_sha256
     OR population.population_fence_sha256<>
          manifest_row.population_fence_sha256
     OR manifest_row.manifest_sha256 IS DISTINCT FROM
          creative_craft_json_sha256(manifest_row.manifest)
     OR manifest_row.manifest_sha256 IS DISTINCT FROM mint_row.manifest_sha256
     OR mint_row.verified_input_set_sha256 IS DISTINCT FROM
          creative_craft_json_sha256(mint_row.verified_input_set)
     OR mint_row.populate_receipt_sha256 IS DISTINCT FROM
          creative_craft_json_sha256(mint_row.populate_receipt)
     OR NOT creative_craft_input_exact_keys(mint_row.attestation,ARRAY[
          'schemaVersion','mintId','manifestSha256','policySha256','planSha256',
          'populationFenceSha256','populationGenerationId',
          'verifiedInputSetSha256','populateReceiptSha256','totalBytes',
          'attestationSha256'])
     OR mint_row.attestation->>'schemaVersion' IS DISTINCT FROM '1'
     OR mint_row.attestation_sha256 IS DISTINCT FROM
          mint_row.attestation->>'attestationSha256'
     OR mint_row.attestation_sha256 IS DISTINCT FROM
          creative_craft_json_sha256(mint_row.attestation-'attestationSha256')
     OR mint_row.attestation->>'mintId' IS DISTINCT FROM
          mint_row.mint_id::text
     OR mint_row.attestation->>'manifestSha256' IS DISTINCT FROM
          mint_row.manifest_sha256
     OR mint_row.attestation->>'verifiedInputSetSha256' IS DISTINCT FROM
          mint_row.verified_input_set_sha256
     OR mint_row.attestation->>'populateReceiptSha256' IS DISTINCT FROM
          mint_row.populate_receipt_sha256
     OR NOT creative_craft_input_exact_keys(mint_row.populate_receipt,
          ARRAY['schemaVersion','inputsSha256'])
     OR mint_row.populate_receipt->>'schemaVersion' IS DISTINCT FROM '1'
     OR NOT coalesce(
          mint_row.populate_receipt->>'inputsSha256' ~ '^[0-9a-f]{64}$',false)
     OR mint_row.verified_input_set->>'sinkReceiptSha256' IS DISTINCT FROM
          mint_row.populate_receipt_sha256
     OR NOT EXISTS(SELECT 1 FROM creative_craft_physical_receipts receipt
          JOIN creative_craft_physical_receipt_consumptions consumed
            ON consumed.user_id=receipt.user_id
           AND consumed.receipt_id=receipt.receipt_id
           AND consumed.completion_kind='materialization'
         WHERE receipt.user_id=p_user_id
           AND receipt.receipt_id=population.receipt_id
           AND receipt.phase='materialization_populate'
           AND receipt.storage_domain_id=population.storage_domain_id
           AND receipt.body#>>'{binding,populationGenerationId}'=
                 population.population_generation_id::text
           AND receipt.body#>>'{binding,populationFenceSha256}'=
                 population.population_fence_sha256
           AND receipt.body#>>'{evidence,planSha256}'=population.plan_sha256
           AND receipt.body#>>'{evidence,inputTreeSha256}'=
                 mint_row.populate_receipt->>'inputsSha256'
           AND consumed.materialization_generation_id=
                 population.population_generation_id)
  THEN RETURN NULL; END IF;
  IF NOT creative_craft_input_assets_current(
      p_user_id,manifest_row.manifest) THEN RETURN NULL; END IF;
  started:=clock_timestamp();
  consumption:=gen_random_uuid();
  claim_token_hash:=creative_craft_json_sha256(to_jsonb(p_claim_lease_token::text));
  receipt_body:=jsonb_build_object(
    'schemaVersion',1,'status','provider_started',
    'consumptionId',consumption::text,'mintId',mint_row.mint_id::text,
    'attemptId',p_attempt_id::text,
    'populationGenerationId',population.population_generation_id::text,
    'attestationSha256',mint_row.attestation_sha256,
    'manifestSha256',mint_row.manifest_sha256,
    'claimLeaseTokenSha256',claim_token_hash,
    'providerStartedAt',to_char(started AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
  receipt_hash:=creative_craft_json_sha256(receipt_body);
  INSERT INTO creative_craft_input_attestation_consumptions(
    user_id,consumption_id,mint_id,attempt_id,intent_id,
    population_generation_id,installation_id,storage_domain_id,job_id,step_id,
    attempt_no,claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,
    dispatch_id,request_sha256,plan_sha256,population_fence_sha256,
    manifest_sha256,verified_input_set_sha256,populate_receipt_sha256,
    attestation_sha256,provider_started_at,receipt,receipt_sha256)
  VALUES(p_user_id,consumption,mint_row.mint_id,p_attempt_id,
    intent_row.intent_id,population.population_generation_id,
    binding.installation_id,population.storage_domain_id,attempt_row.job_id,
    attempt_row.step_id,attempt_row.attempt_no,p_claim_lease_token,
    attempt_row.fence_epoch,attempt_row.admission_sha256,
    attempt_row.claim_set_sha256,reservation.dispatch_id,
    reservation.request_sha256,population.plan_sha256,
    population.population_fence_sha256,mint_row.manifest_sha256,
    mint_row.verified_input_set_sha256,mint_row.populate_receipt_sha256,
    mint_row.attestation_sha256,started,receipt_body,receipt_hash);
  UPDATE creative_execution_attempts SET provider_started_at=started,
    usage='{"attemptedCalls":1,"uncertainCalls":1}'::jsonb,
    updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND id=p_attempt_id;
  UPDATE creative_execution_steps SET provider_started_at=started,
    updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND job_id=attempt_row.job_id
     AND step_id=attempt_row.step_id;
  RETURN jsonb_build_object('status','provider_started',
    'dispatchAuthorized',true,'consumptionId',consumption::text,
    'mintId',mint_row.mint_id::text,'receipt',receipt_body,
    'receiptSha256',receipt_hash);
END $$;

CREATE OR REPLACE FUNCTION creative_craft_provider_start_requires_materialization()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE manifest_row record; consumption record;
BEGIN
  IF NEW.provider_started_at IS NOT NULL AND OLD.provider_started_at IS NULL
     AND EXISTS(SELECT 1 FROM creative_execution_steps s
       JOIN creative_execution_jobs j ON j.user_id=s.user_id AND j.id=s.job_id
      WHERE s.user_id=NEW.user_id AND s.job_id=NEW.job_id
        AND s.step_id=NEW.step_id AND s.kind='craft'
        AND coalesce((j.graph_snapshot->>'schemaVersion')::integer,1)>=2)
     AND NOT EXISTS(
       SELECT 1 FROM creative_craft_materialization_intents intent
       JOIN creative_craft_launcher_reservations reservation
         ON reservation.user_id=intent.user_id
        AND reservation.materialization_intent_id=intent.intent_id
        AND reservation.attempt_id=intent.attempt_id
       JOIN creative_craft_materialization_populations population
         ON population.user_id=reservation.user_id
        AND population.intent_id=reservation.materialization_intent_id
        AND population.attempt_id=reservation.attempt_id
        AND population.population_generation_id=
              reservation.materialization_generation_id
        AND population.storage_domain_id=reservation.storage_domain_id
      WHERE intent.user_id=NEW.user_id AND intent.attempt_id=NEW.id
        AND intent.state='attached' AND population.state='attached'
        AND reservation.compensation_status='confirmed'
        AND reservation.reserved_at IS NOT NULL
        AND reservation.reservation_receipt=jsonb_build_object(
          'schemaVersion',1,'dispatchId',reservation.dispatch_id::text,
          'requestSha256',reservation.request_sha256,'status','reserved',
          'authoritySha256',reservation.authority_sha256,
          'profileSha256',reservation.profile_sha256)
        AND reservation.reservation_receipt_sha256=
          creative_craft_json_sha256(reservation.reservation_receipt)) THEN
    RAISE EXCEPTION 'Craft provider start requires exact attached population and reserve'
      USING ERRCODE='55000';
  END IF;
  IF NEW.provider_started_at IS NOT NULL AND OLD.provider_started_at IS NULL THEN
    IF EXISTS(SELECT 1 FROM creative_craft_input_manifests
               WHERE user_id=NEW.user_id AND attempt_id=NEW.id) THEN
      SELECT * INTO consumption
        FROM creative_craft_input_attestation_consumptions
       WHERE user_id=NEW.user_id AND attempt_id=NEW.id;
      IF consumption.consumption_id IS NULL
         OR consumption.provider_started_at<>NEW.provider_started_at
      THEN
        RAISE EXCEPTION 'Craft provider start requires one exact input consumption'
          USING ERRCODE='55000';
      END IF;
      SELECT * INTO manifest_row FROM creative_craft_input_manifests
       WHERE user_id=NEW.user_id AND mint_id=consumption.mint_id
         AND attempt_id=NEW.id
         AND intent_id=consumption.intent_id
         AND population_generation_id=consumption.population_generation_id;
      IF manifest_row.mint_id IS NULL
         OR consumption.manifest_sha256<>manifest_row.manifest_sha256
         OR consumption.plan_sha256<>manifest_row.plan_sha256
         OR consumption.population_fence_sha256<>
              manifest_row.population_fence_sha256
         OR EXISTS(SELECT 1 FROM creative_craft_input_cancellations c
                    WHERE c.user_id=NEW.user_id
                      AND c.intent_id=manifest_row.intent_id)
         OR NOT creative_craft_input_assets_current(
              NEW.user_id,manifest_row.manifest) THEN
        RAISE EXCEPTION 'Craft provider start requires one exact input consumption'
          USING ERRCODE='55000';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE FUNCTION creative_craft_step_provider_start_requires_input_consumption()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.provider_started_at IS NOT NULL AND OLD.provider_started_at IS NULL
     AND EXISTS(SELECT 1 FROM creative_craft_input_manifests manifest
      WHERE manifest.user_id=NEW.user_id
        AND manifest.attempt_id=(SELECT attempt.id
          FROM creative_execution_attempts attempt
         WHERE attempt.user_id=NEW.user_id AND attempt.job_id=NEW.job_id
           AND attempt.step_id=NEW.step_id AND attempt.status='running'))
     AND NOT EXISTS(SELECT 1
       FROM creative_execution_attempts attempt
       JOIN creative_craft_input_attestation_consumptions consumption
         ON consumption.user_id=attempt.user_id
        AND consumption.attempt_id=attempt.id
        AND consumption.provider_started_at=NEW.provider_started_at
      WHERE attempt.user_id=NEW.user_id AND attempt.job_id=NEW.job_id
        AND attempt.step_id=NEW.step_id
        AND attempt.provider_started_at=NEW.provider_started_at) THEN
    RAISE EXCEPTION 'Craft step start requires its exact input consumption'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER creative_craft_step_provider_start_requires_input_consumption
BEFORE UPDATE OF provider_started_at ON creative_execution_steps
FOR EACH ROW EXECUTE FUNCTION
  creative_craft_step_provider_start_requires_input_consumption();

CREATE OR REPLACE FUNCTION creative_craft_input_cancel_request(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_request_id uuid,
  p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; intent_row record; population record; stored record;
        was_attached boolean:=false;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  IF p_user_id IS NULL OR p_attempt_id IS NULL OR p_intent_id IS NULL
     OR p_request_id IS NULL OR p_reason IS NULL OR p_reason NOT IN
      ('owner_cancelled','account_deletion','lease_lost','deadline_exceeded') THEN
    RAISE EXCEPTION 'Craft input cancel reason is not closed'
      USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR (owner_row.deletion_requested_at IS NOT NULL
                    AND p_reason<>'account_deletion') THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(
    creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND attempt_id=p_attempt_id FOR UPDATE;
  IF intent_row.intent_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO population FROM creative_craft_materialization_populations
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND state IN ('claimed_unbound','writing','receipt_ready','finalizing',
                   'attached','legacy_attached','cleanup_required',
                   'cleanup_running','cleanup_committed')
   ORDER BY generation_no DESC LIMIT 1 FOR UPDATE;
  was_attached:=population.attached_at IS NOT NULL;
  INSERT INTO creative_craft_input_cancellations(
    user_id,intent_id,attempt_id,request_id,population_generation_id,state,reason)
  VALUES(p_user_id,p_intent_id,p_attempt_id,p_request_id,
    population.population_generation_id,'cancel_pending',p_reason)
  ON CONFLICT (user_id,intent_id) DO NOTHING;
  SELECT * INTO stored FROM creative_craft_input_cancellations
   WHERE user_id=p_user_id AND intent_id=p_intent_id FOR UPDATE;
  IF stored.request_id<>p_request_id OR stored.reason<>p_reason THEN
    RAISE EXCEPTION 'Craft input cancel retry diverged' USING ERRCODE='40001';
  END IF;
  IF population.population_generation_id IS NULL
     AND stored.population_generation_id IS NOT NULL THEN
    SELECT * INTO population FROM creative_craft_materialization_populations
     WHERE user_id=p_user_id
       AND population_generation_id=stored.population_generation_id FOR UPDATE;
  END IF;
  was_attached:=coalesce(population.attached_at IS NOT NULL,false);
  IF population.population_generation_id IS NOT NULL THEN
    IF population.state='claimed_unbound' THEN
      UPDATE creative_craft_materialization_populations
         SET state='forgotten',writer_lease_until=NULL,
             forgotten_at=clock_timestamp(),updated_at=clock_timestamp()
       WHERE user_id=p_user_id
         AND population_generation_id=population.population_generation_id;
    ELSIF population.state IN
        ('writing','receipt_ready','finalizing','attached','legacy_attached') THEN
      UPDATE creative_craft_materialization_populations
         SET state='cleanup_required',writer_lease_until=NULL,
             finalize_token=NULL,finalize_lease_until=NULL,
             available_at=clock_timestamp(),updated_at=clock_timestamp()
       WHERE user_id=p_user_id
         AND population_generation_id=population.population_generation_id;
    END IF;
  END IF;
  RETURN jsonb_build_object('requestId',stored.request_id::text,
    'state',stored.state,'intentId',p_intent_id::text,
    'populationGenerationId',stored.population_generation_id::text,
    'physicalCleanupRequired',was_attached);
END $$;

ALTER FUNCTION creative_craft_input_cancel_reconcile(
  uuid,uuid,uuid,uuid,text,text)
  RENAME TO creative_craft_input_cancel_reconcile_raw118;
CREATE FUNCTION creative_craft_input_cancel_reconcile(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_request_id uuid,
  p_outcome text,p_cleanup_receipt_sha256 text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE completed record;
BEGIN
  PERFORM creative_craft_input_require_verifier();
  IF p_user_id IS NULL OR p_attempt_id IS NULL OR p_intent_id IS NULL
     OR p_request_id IS NULL OR p_outcome IS NULL
     OR p_outcome NOT IN ('unknown','completed')
     OR (p_outcome='completed' AND NOT coalesce(
          p_cleanup_receipt_sha256 ~ '^[0-9a-f]{64}$',false))
     OR (p_outcome<>'completed' AND p_cleanup_receipt_sha256 IS NOT NULL)
  THEN RAISE EXCEPTION 'Craft input cancel outcome is not closed'
    USING ERRCODE='22023'; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  IF NOT EXISTS(SELECT 1 FROM users WHERE id=p_user_id
                FOR NO KEY UPDATE) THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(
    creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT cancellation.attempt_id,cancellation.request_id,
         cancellation.population_generation_id,
         cancellation.cleanup_receipt_sha256,
         completion.cleanup_receipt_sha256 AS completion_receipt_sha256
    INTO completed
    FROM creative_craft_input_cancellations cancellation
    JOIN creative_craft_input_cancellation_completions completion
      ON completion.user_id=cancellation.user_id
     AND completion.intent_id=cancellation.intent_id
     AND completion.request_id=cancellation.request_id
     AND completion.population_generation_id=
           cancellation.population_generation_id
   WHERE cancellation.user_id=p_user_id
     AND cancellation.intent_id=p_intent_id;
  IF completed.request_id IS NOT NULL THEN
    IF p_outcome<>'completed'
       OR (completed.attempt_id,completed.request_id,
           completed.cleanup_receipt_sha256,
           completed.completion_receipt_sha256) IS DISTINCT FROM
          (p_attempt_id,p_request_id,p_cleanup_receipt_sha256,
           p_cleanup_receipt_sha256) THEN
      RAISE EXCEPTION 'Craft input cancel reconciliation diverged'
        USING ERRCODE='40001';
    END IF;
    RETURN jsonb_build_object('requestId',p_request_id::text,
      'state','completed','cleanupReceiptSha256',p_cleanup_receipt_sha256);
  ELSIF p_outcome='completed' AND EXISTS(
      SELECT 1 FROM creative_craft_input_cancellations cancellation
      JOIN creative_craft_materialization_populations population
        ON population.user_id=cancellation.user_id
       AND population.population_generation_id=
             cancellation.population_generation_id
     WHERE cancellation.user_id=p_user_id
       AND cancellation.intent_id=p_intent_id
       AND cancellation.attempt_id=p_attempt_id
       AND cancellation.request_id=p_request_id
       AND population.attached_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Attached Craft cancellation requires physical cleanup receipt'
      USING ERRCODE='55000';
  END IF;
  RETURN creative_craft_input_cancel_reconcile_raw118(
    p_user_id,p_attempt_id,p_intent_id,p_request_id,p_outcome,
    p_cleanup_receipt_sha256);
END $$;

CREATE FUNCTION creative_craft_input_complete_attached_cancellation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE cancellation record; receipt record; body jsonb; body_hash text;
BEGIN
  IF NEW.state='forgotten' AND OLD.state<>'forgotten'
     AND NEW.attached_at IS NOT NULL THEN
    SELECT * INTO cancellation FROM creative_craft_input_cancellations
     WHERE user_id=NEW.user_id AND intent_id=NEW.intent_id
       AND attempt_id=NEW.attempt_id
       AND population_generation_id=NEW.population_generation_id
       AND state IN ('cancel_pending','unknown') FOR UPDATE;
    IF cancellation.request_id IS NOT NULL THEN
      SELECT physical.* INTO receipt
        FROM creative_craft_physical_receipts physical
        JOIN creative_craft_physical_challenges challenge
          ON challenge.user_id=physical.user_id
         AND challenge.challenge_id=physical.challenge_id
        JOIN creative_craft_physical_receipt_consumptions consumed
          ON consumed.user_id=physical.user_id
         AND consumed.receipt_id=physical.receipt_id
         AND consumed.completion_kind='materialization_cleanup'
       WHERE physical.user_id=NEW.user_id
         AND physical.phase='materialization_forget'
         AND physical.storage_domain_id=NEW.storage_domain_id
         AND challenge.attempt_id=NEW.attempt_id
         AND challenge.materialization_intent_id=NEW.intent_id
         AND challenge.materialization_generation_id=
               NEW.population_generation_id
         AND challenge.storage_domain_id=NEW.storage_domain_id
         AND consumed.attempt_id=NEW.attempt_id
         AND consumed.materialization_generation_id=
               NEW.population_generation_id
       ORDER BY physical.observed_at DESC LIMIT 1;
      IF receipt.receipt_id IS NULL THEN
        RAISE EXCEPTION 'Attached Craft cancellation lost physical cleanup receipt'
          USING ERRCODE='55000';
      END IF;
      body:=jsonb_build_object(
        'schemaVersion',1,'status','completed',
        'requestId',cancellation.request_id::text,
        'populationGenerationId',NEW.population_generation_id::text,
        'cleanupReceiptId',receipt.receipt_id::text,
        'cleanupReceiptSha256',receipt.receipt_sha256);
      body_hash:=creative_craft_json_sha256(body);
      INSERT INTO creative_craft_input_cancellation_completions(
        user_id,intent_id,request_id,population_generation_id,
        cleanup_receipt_id,cleanup_receipt_sha256,completion,completion_sha256)
      VALUES(NEW.user_id,NEW.intent_id,cancellation.request_id,
        NEW.population_generation_id,receipt.receipt_id,
        receipt.receipt_sha256,body,body_hash);
      UPDATE creative_craft_input_cancellations SET state='completed',
        cleanup_receipt_sha256=receipt.receipt_sha256,
        reconciled_at=clock_timestamp(),
        updated_at=clock_timestamp()
       WHERE user_id=NEW.user_id AND intent_id=NEW.intent_id;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER creative_craft_input_complete_attached_cancellation
AFTER UPDATE OF state ON creative_craft_materialization_populations
FOR EACH ROW EXECUTE FUNCTION
  creative_craft_input_complete_attached_cancellation();

DO $authority$
DECLARE s text:=current_schema(); binding record; caller_roles text; f record;
        role_name text; relation_name text; database_oid oid;
BEGIN
  SELECT t.*,p.receipt_definer_role,p.completion_definer_role,
         p.launcher_verifier_role,p.storage_verifier_role,
         i.input_verifier_role INTO binding
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p USING(installation_key)
    JOIN creative_craft_input_installation_bindings i USING(installation_key);
  SELECT oid INTO database_oid FROM pg_database
   WHERE datname=current_database();
  FOREACH role_name IN ARRAY ARRAY[
      binding.preparer_role,binding.ack_role,binding.escrow_role,
      binding.launcher_verifier_role,binding.storage_verifier_role,
      binding.receipt_definer_role,binding.completion_definer_role,
      binding.input_verifier_role] LOOP
    IF EXISTS(SELECT 1 FROM pg_roles role_row
       WHERE role_row.rolname=role_name AND (
         role_row.rolcanlogin OR role_row.rolinherit OR role_row.rolsuper
         OR role_row.rolcreatedb OR role_row.rolcreaterole
         OR role_row.rolreplication OR role_row.rolbypassrls
         OR EXISTS(SELECT 1 FROM pg_auth_members membership
              WHERE membership.roleid=role_row.oid
                 OR membership.member=role_row.oid)
         OR EXISTS(SELECT 1 FROM pg_shdepend dependency
              WHERE dependency.refclassid='pg_authid'::regclass
                AND dependency.refobjid=role_row.oid
                AND (dependency.dbid<>database_oid
                  OR dependency.deptype NOT IN ('a','o')
                  OR CASE dependency.classid
                    WHEN 'pg_namespace'::regclass THEN NOT EXISTS(
                      SELECT 1 FROM pg_namespace namespace
                       WHERE namespace.oid=dependency.objid
                         AND namespace.nspname=s)
                    WHEN 'pg_proc'::regclass THEN NOT EXISTS(
                      SELECT 1 FROM pg_proc procedure
                      JOIN pg_namespace namespace
                        ON namespace.oid=procedure.pronamespace
                       WHERE procedure.oid=dependency.objid
                         AND namespace.nspname=s
                         AND procedure.proname LIKE 'creative_craft_%')
                    WHEN 'pg_class'::regclass THEN NOT EXISTS(
                      SELECT 1 FROM pg_class relation
                      JOIN pg_namespace namespace
                        ON namespace.oid=relation.relnamespace
                       WHERE relation.oid=dependency.objid
                         AND namespace.nspname=s
                         AND (relation.relname LIKE 'creative_craft_%'
                           OR relation.relname IN (
                             'users','creative_execution_jobs',
                             'creative_execution_steps',
                             'creative_execution_attempts',
                             'creative_execution_admissions',
                             'creative_execution_approvals',
                             'creative_execution_quotes','creative_assets',
                             'creative_asset_revisions','uony_creative_plans',
                             'uony_threads','google_cloud_connections',
                             'creative_runtime_reconciliation_outbox',
                             'creative_candidate_receipts',
                             'creative_candidate_states',
                             'creative_candidate_quarantines',
                             'creative_candidate_quarantine_assets',
                             'creative_candidate_native_projects',
                             'creative_native_project_revisions')))
                    ELSE true END)))) THEN
      RAISE EXCEPTION 'Craft role changed before 119 grants: %',role_name
        USING ERRCODE='55000';
    END IF;
  END LOOP;
  FOREACH role_name IN ARRAY ARRAY[
      binding.preparer_role,binding.ack_role,binding.escrow_role,
      binding.launcher_verifier_role,binding.storage_verifier_role,
      binding.input_verifier_role] LOOP
    FOREACH relation_name IN ARRAY ARRAY[
      'users','creative_execution_jobs','creative_execution_steps',
      'creative_execution_attempts','creative_execution_admissions',
      'creative_execution_approvals','creative_execution_quotes',
      'uony_creative_plans','uony_threads','google_cloud_connections',
      'creative_assets','creative_asset_revisions',
      'creative_craft_launcher_reservations',
      'creative_craft_physical_challenges','creative_craft_physical_receipts',
      'creative_craft_physical_receipt_consumptions',
      'creative_craft_materialization_intents',
      'creative_craft_materialization_populations',
      'creative_craft_input_installation_bindings',
      'creative_craft_input_manifests','creative_craft_input_mints',
      'creative_craft_input_cancellations',
      'creative_craft_input_consumption_installation_bindings',
      'creative_craft_input_attestation_consumptions',
      'creative_craft_input_cancellation_completions'] LOOP
      IF has_table_privilege(role_name,format('%I.%I',s,relation_name),
           'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         OR has_any_column_privilege(role_name,
           format('%I.%I',s,relation_name),
           'SELECT,INSERT,UPDATE,REFERENCES') THEN
        RAISE EXCEPTION 'Craft 119 caller gained direct table access before grants: % on %',
          role_name,relation_name USING ERRCODE='55000';
      END IF;
      IF EXISTS(SELECT 1 FROM pg_class relation
          JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
          JOIN pg_roles owner_role ON owner_role.oid=relation.relowner
         WHERE namespace.nspname=s AND relation.relname=relation_name
           AND owner_role.rolname=role_name) THEN
        RAISE EXCEPTION 'Craft 119 caller owns sensitive relation before grants: % on %',
          role_name,relation_name USING ERRCODE='55000';
      END IF;
    END LOOP;
  END LOOP;
  caller_roles:=concat_ws(',',binding.preparer_role,binding.ack_role,
    binding.escrow_role,binding.launcher_verifier_role,
    binding.storage_verifier_role,binding.input_verifier_role);

  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
    'creative_craft_input_consumption_binding_append_only',
    'creative_craft_input_consumption_ledger_guard',
    'creative_craft_step_provider_start_requires_input_consumption',
    'creative_craft_input_complete_attached_cancellation') LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.signature,
      binding.completion_definer_role);
    EXECUTE format('ALTER FUNCTION %s SET search_path TO pg_catalog,%I,pg_temp',
      f.signature,s);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',
      f.signature,caller_roles);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
    'creative_craft_input_consume_and_provider_start',
    'creative_craft_input_cancel_request',
    'creative_craft_provider_start_requires_materialization') LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.signature,
      binding.completion_definer_role);
    EXECUTE format('ALTER FUNCTION %s SET search_path TO pg_catalog,%I,pg_temp',
      f.signature,s);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',
      f.signature,caller_roles);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
    'creative_craft_input_resume','creative_craft_input_cancel_reconcile',
    'creative_craft_input_cancel_reconcile_raw118') LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.signature,
      binding.receipt_definer_role);
    EXECUTE format('ALTER FUNCTION %s SET search_path TO pg_catalog,%I,pg_temp',
      f.signature,s);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',
      f.signature,caller_roles);
  END LOOP;

  EXECUTE format('REVOKE ALL ON %I.creative_craft_input_consumption_installation_bindings,%I.creative_craft_input_attestation_consumptions,%I.creative_craft_input_cancellation_completions FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',s,s,s,caller_roles);
  EXECUTE format('GRANT SELECT ON %I.creative_craft_input_consumption_installation_bindings,%I.creative_craft_input_attestation_consumptions,%I.creative_craft_input_cancellation_completions,%I.creative_execution_admissions,%I.creative_assets,%I.creative_asset_revisions,%I.creative_craft_input_manifests,%I.creative_craft_input_mints,%I.creative_craft_input_cancellations,%I.creative_craft_physical_receipts,%I.creative_craft_physical_receipt_consumptions TO %I',s,s,s,s,s,s,s,s,s,s,s,binding.completion_definer_role);
  EXECUTE format('GRANT SELECT ON %I.users,%I.creative_execution_approvals,%I.creative_execution_quotes,%I.uony_creative_plans,%I.uony_threads,%I.google_cloud_connections TO %I',s,s,s,s,s,s,binding.completion_definer_role);
  EXECUTE format('GRANT INSERT ON %I.creative_craft_input_attestation_consumptions,%I.creative_craft_input_cancellation_completions TO %I',s,s,binding.completion_definer_role);
  EXECUTE format('GRANT UPDATE(id) ON %I.creative_execution_admissions TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT UPDATE(id) ON %I.creative_execution_approvals,%I.creative_execution_quotes,%I.uony_creative_plans TO %I',s,s,s,binding.completion_definer_role);
  EXECUTE format('GRANT UPDATE(id) ON %I.uony_threads TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT UPDATE(user_id) ON %I.google_cloud_connections TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT UPDATE(consumption_id) ON %I.creative_craft_input_attestation_consumptions TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT UPDATE(state,cleanup_receipt_sha256,reconciled_at,updated_at) ON %I.creative_craft_input_cancellations TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT UPDATE(provider_started_at,usage,updated_at) ON %I.creative_execution_attempts TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT UPDATE(provider_started_at,updated_at) ON %I.creative_execution_steps TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT UPDATE(mint_id) ON %I.creative_craft_input_manifests,%I.creative_craft_input_mints TO %I',s,s,binding.completion_definer_role);
  EXECUTE format('GRANT UPDATE(id) ON %I.creative_assets TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT UPDATE(asset_id) ON %I.creative_asset_revisions TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_input_assets_current(uuid,jsonb),%I.creative_craft_input_exact_keys(jsonb,text[]) TO %I',s,s,binding.completion_definer_role);
  EXECUTE format('GRANT SELECT ON %I.creative_craft_input_consumption_installation_bindings,%I.creative_craft_input_attestation_consumptions,%I.creative_craft_input_cancellation_completions TO %I',s,s,s,binding.receipt_definer_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_input_resume(uuid,uuid,uuid,uuid),%I.creative_craft_input_cancel_reconcile(uuid,uuid,uuid,uuid,text,text) TO %I',s,s,binding.input_verifier_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_input_consume_and_provider_start(uuid,uuid,uuid) TO %I',s,binding.preparer_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_input_cancel_request(uuid,uuid,uuid,uuid,text) TO %I',s,binding.preparer_role);
END $authority$;

DO $audit$
DECLARE s text:=current_schema(); binding record; table_name text;
        role_name text;
BEGIN
  SELECT t.preparer_role,t.ack_role,t.escrow_role,
         p.launcher_verifier_role,p.storage_verifier_role,
         i.input_verifier_role,c.desired_active
    INTO binding
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p USING(installation_key)
    JOIN creative_craft_input_installation_bindings i USING(installation_key)
    JOIN creative_craft_input_consumption_installation_bindings c
      USING(installation_key);
  IF binding.desired_active THEN
    RAISE EXCEPTION 'Craft 119 unexpectedly active' USING ERRCODE='55000';
  END IF;
  FOREACH role_name IN ARRAY ARRAY[
      binding.preparer_role,binding.ack_role,binding.escrow_role,
      binding.launcher_verifier_role,binding.storage_verifier_role,
      binding.input_verifier_role] LOOP
    FOREACH table_name IN ARRAY ARRAY[
      'users','creative_execution_jobs','creative_execution_steps',
      'creative_execution_attempts','creative_execution_admissions',
      'creative_execution_approvals','creative_execution_quotes',
      'uony_creative_plans','uony_threads','google_cloud_connections',
      'creative_assets','creative_asset_revisions',
      'creative_craft_launcher_reservations',
      'creative_craft_physical_challenges','creative_craft_physical_receipts',
      'creative_craft_physical_receipt_consumptions',
      'creative_craft_materialization_intents',
      'creative_craft_materialization_populations',
      'creative_craft_input_installation_bindings',
      'creative_craft_input_manifests','creative_craft_input_mints',
      'creative_craft_input_cancellations',
      'creative_craft_input_consumption_installation_bindings',
      'creative_craft_input_attestation_consumptions',
      'creative_craft_input_cancellation_completions'] LOOP
      IF has_table_privilege(role_name,format('%I.%I',s,table_name),
           'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         OR has_any_column_privilege(role_name,
           format('%I.%I',s,table_name),
           'SELECT,INSERT,UPDATE,REFERENCES') THEN
        RAISE EXCEPTION 'Craft 119 caller gained direct table access: % on %',
          role_name,table_name USING ERRCODE='55000';
      END IF;
      IF EXISTS(SELECT 1 FROM pg_class relation
          JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
          JOIN pg_roles owner_role ON owner_role.oid=relation.relowner
         WHERE namespace.nspname=s AND relation.relname=table_name
           AND owner_role.rolname=role_name) THEN
        RAISE EXCEPTION 'Craft 119 caller owns sensitive relation: % on %',
          role_name,table_name USING ERRCODE='55000';
      END IF;
    END LOOP;
  END LOOP;
  IF NOT has_function_privilege(binding.preparer_role,format(
       '%I.creative_craft_input_consume_and_provider_start(uuid,uuid,uuid)',s),
       'EXECUTE')
     OR has_function_privilege('uonify_app_runtime',format(
       '%I.creative_craft_input_consume_and_provider_start(uuid,uuid,uuid)',s),
       'EXECUTE') THEN
    RAISE EXCEPTION 'Craft 119 exact execute boundary is not closed'
      USING ERRCODE='55000';
  END IF;
END $audit$;
