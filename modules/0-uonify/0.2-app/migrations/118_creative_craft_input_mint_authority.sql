-- Forward-only, inactive Craft input manifest and mint authority.
--
-- This migration persists one manifest and one attestation per population,
-- makes retries deterministic across processes, and installs a durable input
-- cancellation fence.  It does not connect routes, workers, providers, GCS,
-- startup or the product runtime.  desired_active remains false.

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

DO $preflight$
DECLARE binding record; relation_name text; role_name text;
BEGIN
  IF to_regclass('creative_craft_materialization_intents') IS NULL
     OR to_regclass('creative_craft_materialization_populations') IS NULL
     OR to_regprocedure(
       'creative_craft_materialization_renew_population(uuid,uuid,uuid,uuid,uuid)')
        IS NULL
     OR to_regclass('creative_craft_input_installation_bindings') IS NOT NULL
     OR to_regprocedure(
       'creative_craft_input_manifest_register(uuid,uuid,uuid,uuid,uuid,jsonb,text)')
        IS NOT NULL THEN
    RAISE EXCEPTION 'Craft 118 requires one clean 117 installation'
      USING ERRCODE='55000';
  END IF;
  SELECT t.*,p.installation_id,p.storage_domain_id,
         p.launcher_verifier_role,p.storage_verifier_role,
         p.receipt_definer_role,p.completion_definer_role INTO binding
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p
      USING(installation_key)
   WHERE t.database_name=current_database()
     AND t.schema_name=current_schema();
  IF binding.installation_id IS NULL OR binding.desired_active THEN
    RAISE EXCEPTION 'Craft 118 requires one inactive scoped installation'
      USING ERRCODE='55000';
  END IF;
  FOREACH role_name IN ARRAY ARRAY[
      binding.preparer_role,binding.ack_role,binding.escrow_role,
      binding.launcher_verifier_role,binding.storage_verifier_role] LOOP
    FOREACH relation_name IN ARRAY ARRAY[
      'users','creative_execution_jobs','creative_execution_steps',
      'creative_execution_attempts','creative_craft_materialization_intents',
      'creative_craft_materialization_populations'] LOOP
      IF has_table_privilege(role_name,format('%I.%I',current_schema(),
           relation_name),'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
      THEN
        RAISE EXCEPTION 'Craft 118 caller gained direct DML: % on %',
          role_name,relation_name USING ERRCODE='55000';
      END IF;
    END LOOP;
  END LOOP;
END $preflight$;

CREATE TABLE creative_craft_input_installation_bindings (
  installation_id uuid PRIMARY KEY REFERENCES
    creative_craft_physical_installation_bindings(installation_id),
  installation_key text NOT NULL UNIQUE REFERENCES
    creative_craft_transition_installation_bindings(installation_key),
  database_name text NOT NULL,
  schema_name text NOT NULL,
  input_verifier_role text NOT NULL UNIQUE,
  source_code_sha256 text NOT NULL
    CHECK (source_code_sha256 ~ '^[0-9a-f]{64}$'),
  policy jsonb NOT NULL CHECK (jsonb_typeof(policy)='object'),
  policy_sha256 text NOT NULL CHECK (policy_sha256 ~ '^[0-9a-f]{64}$'),
  desired_active boolean NOT NULL DEFAULT false CHECK (NOT desired_active),
  authority_mode text NOT NULL DEFAULT 'inactive_input_mint_v1'
    CHECK (authority_mode='inactive_input_mint_v1'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(database_name,schema_name)
);

CREATE FUNCTION creative_craft_input_binding_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION 'Craft input installation binding is append-only'
    USING ERRCODE='55000';
END $$;
CREATE TRIGGER creative_craft_input_binding_append_only
BEFORE UPDATE OR DELETE ON creative_craft_input_installation_bindings
FOR EACH ROW EXECUTE FUNCTION creative_craft_input_binding_append_only();

DO $role$
DECLARE binding record; role_name text; dirty text;
        policy_body jsonb;
BEGIN
  SELECT t.installation_key,t.database_name,t.schema_name,p.installation_id
    INTO binding
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p USING(installation_key)
   WHERE t.database_name=current_database() AND t.schema_name=current_schema();
  role_name:='uonify_craft_vinput_'||binding.installation_key;
  IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=role_name) THEN
    SELECT CASE
      WHEN r.rolcanlogin OR r.rolinherit OR r.rolsuper OR r.rolcreatedb OR
           r.rolcreaterole OR r.rolreplication OR r.rolbypassrls
        THEN 'capability'
      WHEN EXISTS(SELECT 1 FROM pg_auth_members m
                   WHERE m.roleid=r.oid OR m.member=r.oid)
        THEN 'membership'
      WHEN EXISTS(SELECT 1 FROM pg_shdepend d
                   WHERE d.refclassid='pg_authid'::regclass
                     AND d.refobjid=r.oid AND d.deptype IN ('a','o'))
        THEN 'dependency' END INTO dirty
      FROM pg_roles r WHERE r.rolname=role_name;
    IF dirty IS NOT NULL THEN
      RAISE EXCEPTION 'pre-existing input verifier role contaminated: % (%)',
        role_name,dirty USING ERRCODE='55000';
    END IF;
  ELSE
    EXECUTE format('CREATE ROLE %I NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',role_name);
  END IF;
  EXECUTE format('ALTER ROLE %I NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',role_name);
  policy_body:=jsonb_build_object(
    'schemaVersion',1,'policyId','craft-input-v1','maxInputs',64,
    'maxFileBytes',2147483648,'maxTotalBytes',2147483648,
    'chunkBytes',1048576,'maxManifestBytes',262144,
    'maxPathParts',32,'maxPathBytes',4096,
    'descriptorRelative',true,'noFollow',true,'nonBlockingLeaf',true,
    'sameDescriptorReadAndHash',true,'singleLink',true,
    'sameOwnerAndDevice',true,'deadlineRequired',true,
    'durableCancellationRequired',true);
  INSERT INTO creative_craft_input_installation_bindings(
    installation_id,installation_key,database_name,schema_name,
    input_verifier_role,source_code_sha256,policy,policy_sha256)
  VALUES(binding.installation_id,binding.installation_key,
    binding.database_name,binding.schema_name,role_name,
    '389885d34ab1e2d242e2035ae0c021cec6f78e32c41fc511a1c36a5fec17e4b2',
    policy_body,creative_craft_json_sha256(policy_body));
END $role$;

CREATE TABLE creative_craft_input_manifests (
  user_id uuid NOT NULL,
  mint_id uuid NOT NULL,
  installation_id uuid NOT NULL,
  storage_domain_id uuid NOT NULL,
  attempt_id uuid NOT NULL,
  intent_id uuid NOT NULL,
  population_generation_id uuid NOT NULL,
  population_namespace_id uuid NOT NULL,
  writer_token uuid NOT NULL,
  manifest jsonb NOT NULL CHECK (jsonb_typeof(manifest)='object'),
  manifest_sha256 text NOT NULL CHECK (manifest_sha256 ~ '^[0-9a-f]{64}$'),
  manifest_runtime_sha256 text NOT NULL
    CHECK (manifest_runtime_sha256 ~ '^[0-9a-f]{64}$'),
  policy_sha256 text NOT NULL CHECK (policy_sha256 ~ '^[0-9a-f]{64}$'),
  plan_sha256 text NOT NULL CHECK (plan_sha256 ~ '^[0-9a-f]{64}$'),
  population_fence_sha256 text NOT NULL
    CHECK (population_fence_sha256 ~ '^[0-9a-f]{64}$'),
  input_manifest_sha256 text NOT NULL
    CHECK (input_manifest_sha256 ~ '^[0-9a-f]{64}$'),
  profile_sha256 text NOT NULL CHECK (profile_sha256 ~ '^[0-9a-f]{64}$'),
  image_digest text NOT NULL CHECK (image_digest ~ '^sha256:[0-9a-f]{64}$'),
  binary_sha256 text NOT NULL CHECK (binary_sha256 ~ '^[0-9a-f]{64}$'),
  source_code_sha256 text NOT NULL
    CHECK (source_code_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(user_id,mint_id),
  UNIQUE(mint_id),
  UNIQUE(user_id,population_generation_id),
  UNIQUE(user_id,mint_id,population_generation_id,writer_token,manifest_sha256),
  FOREIGN KEY(user_id,intent_id,attempt_id,population_generation_id)
    REFERENCES creative_craft_materialization_populations
      (user_id,intent_id,attempt_id,population_generation_id),
  FOREIGN KEY(installation_id)
    REFERENCES creative_craft_input_installation_bindings(installation_id),
  CHECK (pg_column_size(manifest)<=262144)
);

CREATE TABLE creative_craft_input_mints (
  user_id uuid NOT NULL,
  mint_id uuid NOT NULL,
  population_generation_id uuid NOT NULL,
  writer_token uuid NOT NULL,
  manifest_sha256 text NOT NULL CHECK (manifest_sha256 ~ '^[0-9a-f]{64}$'),
  verified_input_set jsonb NOT NULL
    CHECK (jsonb_typeof(verified_input_set)='object'),
  verified_input_set_sha256 text NOT NULL
    CHECK (verified_input_set_sha256 ~ '^[0-9a-f]{64}$'),
  populate_receipt jsonb NOT NULL CHECK (jsonb_typeof(populate_receipt)='object'),
  populate_receipt_sha256 text NOT NULL
    CHECK (populate_receipt_sha256 ~ '^[0-9a-f]{64}$'),
  total_bytes bigint NOT NULL CHECK (total_bytes>=0 AND total_bytes<=2147483648),
  attestation jsonb NOT NULL CHECK (jsonb_typeof(attestation)='object'),
  attestation_sha256 text NOT NULL CHECK (attestation_sha256 ~ '^[0-9a-f]{64}$'),
  minted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(user_id,mint_id),
  UNIQUE(user_id,population_generation_id),
  FOREIGN KEY(user_id,mint_id,population_generation_id,writer_token,
              manifest_sha256)
    REFERENCES creative_craft_input_manifests
      (user_id,mint_id,population_generation_id,writer_token,manifest_sha256)
);

CREATE TABLE creative_craft_input_cancellations (
  user_id uuid NOT NULL,
  intent_id uuid NOT NULL,
  attempt_id uuid NOT NULL,
  request_id uuid NOT NULL,
  population_generation_id uuid,
  state text NOT NULL CHECK (state IN ('cancel_pending','unknown','completed')),
  reason text NOT NULL CHECK (reason IN
    ('owner_cancelled','account_deletion','lease_lost','deadline_exceeded')),
  cleanup_receipt_sha256 text
    CHECK (cleanup_receipt_sha256 ~ '^[0-9a-f]{64}$'),
  requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reconciled_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(user_id,intent_id),
  UNIQUE(request_id),
  FOREIGN KEY(user_id,intent_id)
    REFERENCES creative_craft_materialization_intents(user_id,intent_id),
  CHECK ((state='completed')=(cleanup_receipt_sha256 IS NOT NULL)),
  CHECK ((state='cancel_pending')=(reconciled_at IS NULL))
);

CREATE FUNCTION creative_craft_input_ledger_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE receipt_owner text; completion_owner text;
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
    RAISE EXCEPTION 'Craft input ledger is deleted only with its account'
      USING ERRCODE='42501';
  END IF;
  SELECT receipt_definer_role,completion_definer_role
    INTO receipt_owner,completion_owner
    FROM creative_craft_physical_installation_bindings;
  IF TG_TABLE_NAME IN ('creative_craft_input_manifests',
                       'creative_craft_input_mints') THEN
    IF TG_OP='UPDATE' THEN
      RAISE EXCEPTION 'Craft input evidence is append-only'
        USING ERRCODE='55000';
    END IF;
    IF current_user<>receipt_owner THEN
      RAISE EXCEPTION 'Craft input evidence requires private mint authority'
        USING ERRCODE='42501';
    END IF;
    RETURN NEW;
  END IF;
  IF current_user NOT IN (receipt_owner,completion_owner) THEN
    RAISE EXCEPTION 'Craft input cancellation requires scoped authority'
      USING ERRCODE='42501';
  END IF;
  IF TG_OP='UPDATE' THEN
    IF (OLD.user_id,OLD.intent_id,OLD.attempt_id,OLD.request_id,
        OLD.population_generation_id,OLD.reason,OLD.requested_at)
       IS DISTINCT FROM
       (NEW.user_id,NEW.intent_id,NEW.attempt_id,NEW.request_id,
        NEW.population_generation_id,NEW.reason,NEW.requested_at)
       OR NOT ((OLD.state='cancel_pending' AND
                NEW.state IN ('unknown','completed')) OR
               (OLD.state='unknown' AND NEW.state='completed')) THEN
      RAISE EXCEPTION 'invalid Craft input cancellation transition'
        USING ERRCODE='55000';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER creative_craft_input_manifest_guard
BEFORE INSERT OR UPDATE OR DELETE ON creative_craft_input_manifests
FOR EACH ROW EXECUTE FUNCTION creative_craft_input_ledger_guard();
CREATE TRIGGER creative_craft_input_mint_guard
BEFORE INSERT OR UPDATE OR DELETE ON creative_craft_input_mints
FOR EACH ROW EXECUTE FUNCTION creative_craft_input_ledger_guard();
CREATE TRIGGER creative_craft_input_cancellation_guard
BEFORE INSERT OR UPDATE OR DELETE ON creative_craft_input_cancellations
FOR EACH ROW EXECUTE FUNCTION creative_craft_input_ledger_guard();

CREATE FUNCTION creative_craft_input_cancelled_population_fence()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.state IN ('claimed_unbound','writing','receipt_ready','finalizing',
                   'attached','legacy_attached')
     AND EXISTS(SELECT 1 FROM creative_craft_input_cancellations cancellation
                 WHERE cancellation.user_id=NEW.user_id
                   AND cancellation.intent_id=NEW.intent_id) THEN
    RAISE EXCEPTION 'Craft input authority was durably revoked'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER creative_craft_input_cancelled_population_fence
BEFORE INSERT OR UPDATE ON creative_craft_materialization_populations
FOR EACH ROW EXECUTE FUNCTION creative_craft_input_cancelled_population_fence();

CREATE FUNCTION creative_craft_input_exact_keys(value jsonb, expected text[])
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT jsonb_typeof($1)='object' AND
    (SELECT coalesce(array_agg(key ORDER BY key),ARRAY[]::text[])
       FROM jsonb_object_keys($1) key)=
    (SELECT coalesce(array_agg(item ORDER BY item),ARRAY[]::text[])
       FROM unnest($2) item)
$$;

CREATE FUNCTION creative_craft_input_assets_current(
  p_user_id uuid,p_manifest jsonb) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE mismatch boolean;
BEGIN
  PERFORM asset.id
    FROM jsonb_array_elements(p_manifest->'entries') entry
    JOIN creative_assets asset
      ON asset.user_id=p_user_id AND asset.id=(entry->>'assetId')::uuid
    JOIN creative_asset_revisions revision
      ON revision.user_id=p_user_id AND revision.asset_id=asset.id
     AND revision.revision=(entry->>'assetRevision')::integer
   ORDER BY asset.id,revision.revision
   FOR UPDATE OF asset,revision;
  SELECT bool_or(coalesce((
      asset.id IS NULL OR revision.asset_id IS NULL
      OR asset.authorization_state IS DISTINCT FROM 'allowed'
      OR asset.current_revision IS DISTINCT FROM
           (entry->>'assetRevision')::integer
      OR revision.snapshot_sha256 IS DISTINCT FROM entry->>'snapshotSha256'
      OR revision.sha256 IS DISTINCT FROM entry->>'expectedSha256'
      OR revision.byte_size IS DISTINCT FROM (entry->>'expectedBytes')::bigint
      OR revision.storage_bucket IS DISTINCT FROM entry#>>'{storageReceipt,bucket}'
      OR revision.storage_name IS DISTINCT FROM entry#>>'{storageReceipt,name}'
      OR revision.storage_generation IS DISTINCT FROM
           (entry#>>'{storageReceipt,generation}')::bigint
      ),true)) INTO mismatch
    FROM jsonb_array_elements(p_manifest->'entries') entry
    LEFT JOIN creative_assets asset
      ON asset.user_id=p_user_id AND asset.id=(entry->>'assetId')::uuid
    LEFT JOIN creative_asset_revisions revision
      ON revision.user_id=p_user_id AND revision.asset_id=asset.id
     AND revision.revision=(entry->>'assetRevision')::integer;
  RETURN NOT coalesce(mismatch,true);
END $$;

CREATE FUNCTION creative_craft_input_require_verifier() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE expected_role text;
BEGIN
  SELECT input_verifier_role INTO expected_role
    FROM creative_craft_input_installation_bindings;
  IF expected_role IS NULL OR
     current_setting('role',true) IS DISTINCT FROM expected_role THEN
    RAISE EXCEPTION 'Craft input verifier role required'
      USING ERRCODE='42501';
  END IF;
END $$;

CREATE FUNCTION creative_craft_input_manifest_register(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_generation_id uuid,
  p_writer_token uuid,p_manifest jsonb,p_manifest_runtime_sha256 text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record; population record; binding record;
        mint uuid; manifest_hash text; entry_count integer; expected_total bigint;
        mismatch boolean; inserted integer; existing record; stored record;
BEGIN
  PERFORM creative_craft_input_require_verifier();
  IF p_user_id IS NULL OR p_attempt_id IS NULL OR p_intent_id IS NULL
     OR p_generation_id IS NULL OR p_writer_token IS NULL OR p_manifest IS NULL
     OR NOT coalesce(p_manifest_runtime_sha256 ~ '^[0-9a-f]{64}$',false)
     OR NOT creative_craft_input_exact_keys(p_manifest,ARRAY[
       'schemaVersion','mintId','installationId','storageDomainId','ownerUserId',
       'attemptId','intentId','populationGenerationId','namespaceId','dispatchId',
       'requestSha256','planSha256','populationFenceSha256',
       'inputManifestSha256','profileSha256','imageDigest','binarySha256',
       'sourceCodeSha256','sourceRoot','policy','policySha256','entries']) THEN
    RAISE EXCEPTION 'Craft input manifest is not closed' USING ERRCODE='22023';
  END IF;
  BEGIN mint:=(p_manifest->>'mintId')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Craft input mintId is not canonical' USING ERRCODE='22023';
  END;
  IF mint IS NULL THEN
    RAISE EXCEPTION 'Craft input mintId is not canonical' USING ERRCODE='22023';
  END IF;
  manifest_hash:=creative_craft_json_sha256(p_manifest);
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR owner_row.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  IF EXISTS(SELECT 1 FROM creative_craft_input_cancellations cancellation
             WHERE cancellation.user_id=p_user_id
               AND cancellation.intent_id=p_intent_id) THEN
    RETURN NULL;
  END IF;
  SELECT * INTO existing FROM creative_craft_input_manifests
   WHERE user_id=p_user_id AND population_generation_id=p_generation_id
   FOR UPDATE;
  IF existing.mint_id IS NOT NULL THEN
    IF (existing.mint_id,existing.attempt_id,existing.intent_id,
        existing.writer_token,existing.manifest,existing.manifest_sha256,
        existing.manifest_runtime_sha256) IS DISTINCT FROM
       (mint,p_attempt_id,p_intent_id,p_writer_token,p_manifest,manifest_hash,
        p_manifest_runtime_sha256) THEN
      RAISE EXCEPTION 'Craft input manifest retry diverged'
        USING ERRCODE='40001';
    END IF;
    IF NOT creative_craft_input_assets_current(p_user_id,existing.manifest) THEN
      RETURN NULL;
    END IF;
    RETURN jsonb_build_object('created',false,'mintId',mint::text,
      'manifestSha256',manifest_hash,
      'manifestRuntimeSha256',p_manifest_runtime_sha256,
      'populationGenerationId',p_generation_id::text);
  END IF;
  SELECT job_id,step_id INTO seed FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO job_row FROM creative_execution_jobs
   WHERE user_id=p_user_id AND id=seed.job_id FOR UPDATE;
  SELECT * INTO step_row FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=seed.job_id AND step_id=seed.step_id FOR UPDATE;
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND attempt_id=p_attempt_id
   FOR UPDATE;
  SELECT * INTO population FROM creative_craft_materialization_populations
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND attempt_id=p_attempt_id
     AND population_generation_id=p_generation_id FOR UPDATE;
  SELECT input.*,physical.storage_domain_id INTO binding
    FROM creative_craft_input_installation_bindings input
    JOIN creative_craft_physical_installation_bindings physical
      USING(installation_id);
  IF population.population_generation_id IS NULL
     OR EXISTS(SELECT 1 FROM creative_craft_input_cancellations cancellation
                WHERE cancellation.user_id=p_user_id
                  AND cancellation.intent_id=p_intent_id)
     OR intent_row.state<>'writing' OR population.state<>'writing'
     OR population.writer_token<>p_writer_token
     OR population.writer_lease_until<=clock_timestamp()
     OR clock_timestamp()>=population.created_at+interval '15 minutes'
     OR job_row.status<>'running' OR step_row.status<>'running'
     OR attempt_row.status<>'running' OR step_row.kind<>'craft'
     OR NOT step_row.provider_call
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR step_row.provider_started_at IS NOT NULL
     OR step_row.provider_returned_at IS NOT NULL
     OR job_row.lease_until<=clock_timestamp()
     OR step_row.lease_until<=clock_timestamp()
     OR attempt_row.lease_until<=clock_timestamp()
     OR job_row.lease_token<>attempt_row.lease_token
     OR step_row.lease_token<>attempt_row.lease_token
     OR attempt_row.claim_lease_token<>intent_row.claim_lease_token
     OR attempt_row.fence_epoch<>intent_row.fence_epoch
     OR population.installation_id<>binding.installation_id
     OR population.storage_domain_id<>binding.storage_domain_id
     OR creative_craft_json_sha256(population.plan)<>population.plan_sha256
  THEN RETURN NULL; END IF;
  IF (p_manifest->>'schemaVersion') IS DISTINCT FROM '1'
     OR p_manifest->>'installationId' IS DISTINCT FROM binding.installation_id::text
     OR p_manifest->>'storageDomainId' IS DISTINCT FROM binding.storage_domain_id::text
     OR p_manifest->>'ownerUserId' IS DISTINCT FROM p_user_id::text
     OR p_manifest->>'attemptId' IS DISTINCT FROM p_attempt_id::text
     OR p_manifest->>'intentId' IS DISTINCT FROM p_intent_id::text
     OR p_manifest->>'populationGenerationId' IS DISTINCT FROM p_generation_id::text
     OR p_manifest->>'namespaceId' IS DISTINCT FROM population.population_namespace_id::text
     OR p_manifest->>'dispatchId' IS DISTINCT FROM intent_row.dispatch_id::text
     OR p_manifest->>'requestSha256' IS DISTINCT FROM population.request_sha256
     OR p_manifest->>'planSha256' IS DISTINCT FROM population.plan_sha256
     OR p_manifest->>'populationFenceSha256' IS DISTINCT FROM population.population_fence_sha256
     OR p_manifest->>'inputManifestSha256' IS DISTINCT FROM
          attempt_row.craft_resolved_input_manifest_sha256
     OR p_manifest->>'profileSha256' IS DISTINCT FROM population.profile_sha256
     OR p_manifest->>'imageDigest' IS DISTINCT FROM
          population.plan#>>'{profile,imageDigest}'
     OR p_manifest->>'binarySha256' IS DISTINCT FROM
          population.plan#>>'{profile,binarySha256}'
     OR p_manifest->>'sourceCodeSha256' IS DISTINCT FROM binding.source_code_sha256
     OR p_manifest->'policy' IS DISTINCT FROM binding.policy
     OR p_manifest->>'policySha256' IS DISTINCT FROM binding.policy_sha256
     OR NOT creative_craft_input_exact_keys(p_manifest->'sourceRoot',
          ARRAY['device','inode','ownerUid','mode'])
     OR NOT coalesce((p_manifest#>>'{sourceRoot,device}') ~ '^[0-9]+$',false)
     OR NOT coalesce((p_manifest#>>'{sourceRoot,inode}') ~ '^[0-9]+$',false)
     OR NOT coalesce((p_manifest#>>'{sourceRoot,ownerUid}') ~ '^[0-9]+$',false)
     OR NOT coalesce((p_manifest#>>'{sourceRoot,mode}') ~ '^[0-9]+$',false)
     OR jsonb_typeof(p_manifest->'entries')<>'array'
     OR pg_column_size(p_manifest)>((binding.policy->>'maxManifestBytes')::integer)
  THEN RAISE EXCEPTION 'Craft input manifest is not server-owned'
    USING ERRCODE='22023'; END IF;
  entry_count:=jsonb_array_length(p_manifest->'entries');
  IF entry_count<1 OR entry_count>(binding.policy->>'maxInputs')::integer
     OR entry_count<>jsonb_array_length(population.plan->'inputs')
     OR entry_count<>jsonb_array_length(attempt_row.craft_resolved_job_snapshot->'inputs')
  THEN RAISE EXCEPTION 'Craft input manifest entry count is unsafe'
    USING ERRCODE='22023'; END IF;
  SELECT coalesce(sum((entry->>'expectedBytes')::bigint),0),bool_or(coalesce((
      NOT creative_craft_input_exact_keys(entry,ARRAY[
        'assetId','ownerUserId','relativePath','expectedSha256','expectedBytes',
        'sourceRelativePath','assetRevision','storageReceipt','snapshotSha256'])
      OR entry->>'assetId'<>plan_input->>'assetId'
      OR entry->>'ownerUserId'<>p_user_id::text
      OR entry->>'relativePath'<>plan_input->>'relativePath'
      OR entry->>'expectedSha256'<>plan_input->>'expectedSha256'
      OR entry->>'expectedBytes'<>plan_input->>'expectedBytes'
      OR entry->>'assetId'<>resolved->>'assetId'
      OR entry->>'assetRevision'<>resolved->>'assetRevision'
      OR entry->>'relativePath'<>resolved->>'mountName'
      OR entry->>'expectedSha256'<>resolved->>'sha256'
      OR entry->>'expectedBytes'<>resolved->>'bytes'
      OR NOT creative_craft_input_exact_keys(entry->'storageReceipt',
           ARRAY['bucket','name','generation'])
      OR entry#>>'{storageReceipt,bucket}'<>
           resolved#>>'{storageReceipt,bucket}'
      OR entry#>>'{storageReceipt,name}'<>
           resolved#>>'{storageReceipt,name}'
      OR entry#>>'{storageReceipt,generation}'<>
           resolved#>>'{storageReceipt,generation}'
      OR entry->>'sourceRelativePath' !~ '^[^/\\]+(/[^/\\]+)*$'
      OR entry->>'sourceRelativePath' ~ '(^|/)\.\.(/|$)'
      OR asset.id IS NULL OR revision.asset_id IS NULL
      OR asset.authorization_state<>'allowed'
      OR asset.current_revision<>(entry->>'assetRevision')::integer
      OR revision.snapshot_sha256<>entry->>'snapshotSha256'
      OR revision.sha256<>entry->>'expectedSha256'
      OR revision.byte_size<>(entry->>'expectedBytes')::bigint
      OR revision.storage_bucket<>entry#>>'{storageReceipt,bucket}'
      OR revision.storage_name<>entry#>>'{storageReceipt,name}'
      OR revision.storage_generation<>(entry#>>'{storageReceipt,generation}')::bigint
      ),true))
    INTO expected_total,mismatch
    FROM jsonb_array_elements(p_manifest->'entries') WITH ORDINALITY e(entry,n)
    JOIN jsonb_array_elements(population.plan->'inputs') WITH ORDINALITY
      p(plan_input,n) USING(n)
    JOIN jsonb_array_elements(attempt_row.craft_resolved_job_snapshot->'inputs')
      WITH ORDINALITY r(resolved,n) USING(n)
    LEFT JOIN creative_assets asset
      ON asset.user_id=p_user_id AND asset.id=(entry->>'assetId')::uuid
    LEFT JOIN creative_asset_revisions revision
      ON revision.user_id=p_user_id AND revision.asset_id=asset.id
     AND revision.revision=(entry->>'assetRevision')::integer;
  IF coalesce(mismatch,true)
     OR expected_total>(binding.policy->>'maxTotalBytes')::bigint THEN
    RAISE EXCEPTION 'Craft input entries do not match durable assets'
      USING ERRCODE='22023';
  END IF;
  IF NOT creative_craft_input_assets_current(p_user_id,p_manifest) THEN
    RETURN NULL;
  END IF;
  INSERT INTO creative_craft_input_manifests(
    user_id,mint_id,installation_id,storage_domain_id,attempt_id,intent_id,
    population_generation_id,population_namespace_id,writer_token,manifest,
    manifest_sha256,manifest_runtime_sha256,policy_sha256,plan_sha256,
    population_fence_sha256,input_manifest_sha256,profile_sha256,image_digest,
    binary_sha256,source_code_sha256)
  VALUES(p_user_id,mint,binding.installation_id,binding.storage_domain_id,
    p_attempt_id,p_intent_id,p_generation_id,population.population_namespace_id,
    p_writer_token,p_manifest,manifest_hash,p_manifest_runtime_sha256,
    binding.policy_sha256,population.plan_sha256,
    population.population_fence_sha256,
    attempt_row.craft_resolved_input_manifest_sha256,population.profile_sha256,
    p_manifest->>'imageDigest',p_manifest->>'binarySha256',
    binding.source_code_sha256)
  ON CONFLICT (user_id,population_generation_id) DO NOTHING;
  GET DIAGNOSTICS inserted=ROW_COUNT;
  SELECT * INTO stored FROM creative_craft_input_manifests
   WHERE user_id=p_user_id AND population_generation_id=p_generation_id FOR UPDATE;
  IF (stored.mint_id,stored.writer_token,stored.manifest,stored.manifest_sha256,
      stored.manifest_runtime_sha256) IS DISTINCT FROM
     (mint,p_writer_token,p_manifest,manifest_hash,p_manifest_runtime_sha256) THEN
    RAISE EXCEPTION 'Craft input manifest retry diverged'
      USING ERRCODE='40001';
  END IF;
  RETURN jsonb_build_object('created',inserted=1,'mintId',mint::text,
    'manifestSha256',manifest_hash,
    'manifestRuntimeSha256',p_manifest_runtime_sha256,
    'populationGenerationId',p_generation_id::text);
END $$;

CREATE FUNCTION creative_craft_input_mint(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_generation_id uuid,
  p_writer_token uuid,p_mint_id uuid,p_verified_input_set jsonb,
  p_populate_receipt jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record; population record; manifest_row record;
        verified_hash text; receipt_hash text; attestation_body jsonb;
        attestation_hash text; total bigint; mismatch boolean; inserted integer;
        existing record; stored record;
BEGIN
  PERFORM creative_craft_input_require_verifier();
  IF p_user_id IS NULL OR p_attempt_id IS NULL OR p_intent_id IS NULL
     OR p_generation_id IS NULL OR p_writer_token IS NULL OR p_mint_id IS NULL
     OR p_verified_input_set IS NULL OR p_populate_receipt IS NULL
     OR NOT creative_craft_input_exact_keys(p_verified_input_set,ARRAY[
       'schemaVersion','manifestSha256','manifestRuntimeSha256','observations',
       'totalBytes','sinkReceiptSha256'])
     OR jsonb_typeof(p_populate_receipt)<>'object'
     OR NOT creative_craft_input_exact_keys(p_populate_receipt,ARRAY[
          'schemaVersion','inputsSha256'])
     OR jsonb_typeof(p_verified_input_set->'observations')<>'array'
     OR NOT coalesce((p_verified_input_set->>'totalBytes') ~ '^[0-9]+$',false)
     OR (p_populate_receipt->>'schemaVersion') IS DISTINCT FROM '1'
     OR NOT coalesce((p_populate_receipt->>'inputsSha256') ~ '^[0-9a-f]{64}$',false)
  THEN
    RAISE EXCEPTION 'Craft verified input set is not closed'
      USING ERRCODE='22023';
  END IF;
  verified_hash:=creative_craft_json_sha256(p_verified_input_set);
  receipt_hash:=creative_craft_json_sha256(p_populate_receipt);
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR owner_row.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  IF EXISTS(SELECT 1 FROM creative_craft_input_cancellations cancellation
             WHERE cancellation.user_id=p_user_id
               AND cancellation.intent_id=p_intent_id) THEN
    RETURN NULL;
  END IF;
  SELECT minted.*,manifest.attempt_id AS manifest_attempt_id,
         manifest.intent_id AS manifest_intent_id,
         manifest.manifest AS stored_manifest
    INTO existing
    FROM creative_craft_input_mints minted
    JOIN creative_craft_input_manifests manifest
      ON manifest.user_id=minted.user_id AND manifest.mint_id=minted.mint_id
   WHERE minted.user_id=p_user_id AND minted.mint_id=p_mint_id
   FOR UPDATE OF minted,manifest;
  IF existing.mint_id IS NOT NULL THEN
    IF (existing.manifest_attempt_id,existing.manifest_intent_id,
        existing.population_generation_id,existing.writer_token,
        existing.verified_input_set,existing.verified_input_set_sha256,
        existing.populate_receipt,existing.populate_receipt_sha256) IS DISTINCT FROM
       (p_attempt_id,p_intent_id,p_generation_id,p_writer_token,
        p_verified_input_set,verified_hash,p_populate_receipt,receipt_hash) THEN
      RAISE EXCEPTION 'Craft input mint retry diverged' USING ERRCODE='40001';
    END IF;
    IF NOT creative_craft_input_assets_current(
        p_user_id,existing.stored_manifest) THEN
      RETURN NULL;
    END IF;
    RETURN jsonb_build_object('created',false,
      'attestation',existing.attestation,
      'attestationSha256',existing.attestation_sha256);
  END IF;
  SELECT job_id,step_id INTO seed FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO job_row FROM creative_execution_jobs
   WHERE user_id=p_user_id AND id=seed.job_id FOR UPDATE;
  SELECT * INTO step_row FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=seed.job_id AND step_id=seed.step_id FOR UPDATE;
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND attempt_id=p_attempt_id
   FOR UPDATE;
  SELECT * INTO population FROM creative_craft_materialization_populations
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND attempt_id=p_attempt_id
     AND population_generation_id=p_generation_id FOR UPDATE;
  SELECT * INTO manifest_row FROM creative_craft_input_manifests
   WHERE user_id=p_user_id AND mint_id=p_mint_id
     AND population_generation_id=p_generation_id FOR UPDATE;
  IF manifest_row.mint_id IS NULL
     OR EXISTS(SELECT 1 FROM creative_craft_input_cancellations cancellation
                WHERE cancellation.user_id=p_user_id
                  AND cancellation.intent_id=p_intent_id)
     OR intent_row.state<>'writing' OR population.state<>'writing'
     OR population.writer_token<>p_writer_token
     OR manifest_row.writer_token<>p_writer_token
     OR population.writer_lease_until<=clock_timestamp()
     OR clock_timestamp()>=population.created_at+interval '15 minutes'
     OR job_row.status<>'running' OR step_row.status<>'running'
     OR attempt_row.status<>'running' OR step_row.kind<>'craft'
     OR NOT step_row.provider_call
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR step_row.provider_started_at IS NOT NULL
     OR step_row.provider_returned_at IS NOT NULL
     OR job_row.lease_until<=clock_timestamp()
     OR step_row.lease_until<=clock_timestamp()
     OR attempt_row.lease_until<=clock_timestamp()
     OR job_row.lease_token<>attempt_row.lease_token
     OR step_row.lease_token<>attempt_row.lease_token
     OR attempt_row.claim_lease_token<>intent_row.claim_lease_token
     OR attempt_row.fence_epoch<>intent_row.fence_epoch
  THEN RETURN NULL; END IF;
  IF NOT creative_craft_input_assets_current(
      p_user_id,manifest_row.manifest) THEN RETURN NULL; END IF;
  total:=(p_verified_input_set->>'totalBytes')::bigint;
  IF p_verified_input_set->>'schemaVersion' IS DISTINCT FROM '1'
     OR p_verified_input_set->>'manifestSha256' IS DISTINCT FROM manifest_row.manifest_sha256
     OR p_verified_input_set->>'manifestRuntimeSha256' IS DISTINCT FROM
          manifest_row.manifest_runtime_sha256
     OR p_verified_input_set->>'sinkReceiptSha256' IS DISTINCT FROM receipt_hash
     OR jsonb_array_length(p_verified_input_set->'observations')<>
          jsonb_array_length(manifest_row.manifest->'entries')
  THEN RAISE EXCEPTION 'Craft verified set does not bind manifest and receipt'
    USING ERRCODE='22023'; END IF;
  SELECT bool_or(coalesce((
      NOT creative_craft_input_exact_keys(observation,ARRAY[
        'relativePath','device','inode','ownerUid','mode','linkCount',
        'byteSize','sha256','mtimeNs','ctimeNs'])
      OR NOT coalesce((observation->>'device') ~ '^[0-9]+$',false)
      OR NOT coalesce((observation->>'inode') ~ '^[0-9]+$',false)
      OR NOT coalesce((observation->>'ownerUid') ~ '^[0-9]+$',false)
      OR NOT coalesce((observation->>'mode') ~ '^[0-9]+$',false)
      OR NOT coalesce((observation->>'linkCount') ~ '^[0-9]+$',false)
      OR NOT coalesce((observation->>'byteSize') ~ '^[0-9]+$',false)
      OR NOT coalesce((observation->>'mtimeNs') ~ '^[0-9]+$',false)
      OR NOT coalesce((observation->>'ctimeNs') ~ '^[0-9]+$',false)
      OR observation->>'relativePath'<>entry->>'relativePath'
      OR observation->>'sha256'<>entry->>'expectedSha256'
      OR observation->>'byteSize'<>entry->>'expectedBytes'
      OR observation->>'device'<>manifest_row.manifest#>>'{sourceRoot,device}'
      OR observation->>'ownerUid'<>manifest_row.manifest#>>'{sourceRoot,ownerUid}'
      OR observation->>'linkCount'<>'1'
      OR (observation->>'mode')::integer & 18<>0
      ),true))
    INTO mismatch
    FROM jsonb_array_elements(p_verified_input_set->'observations')
      WITH ORDINALITY o(observation,n)
    JOIN jsonb_array_elements(manifest_row.manifest->'entries')
      WITH ORDINALITY e(entry,n) USING(n);
  SELECT coalesce(sum((entry->>'expectedBytes')::bigint),0)
    INTO total FROM jsonb_array_elements(manifest_row.manifest->'entries') entry;
  IF coalesce(mismatch,true) OR total<>(p_verified_input_set->>'totalBytes')::bigint
  THEN RAISE EXCEPTION 'Craft descriptor observations are not exact'
    USING ERRCODE='22023'; END IF;
  attestation_body:=jsonb_build_object(
    'schemaVersion',1,'mintId',p_mint_id::text,
    'manifestSha256',manifest_row.manifest_sha256,
    'policySha256',manifest_row.policy_sha256,
    'planSha256',manifest_row.plan_sha256,
    'populationFenceSha256',manifest_row.population_fence_sha256,
    'populationGenerationId',p_generation_id::text,
    'verifiedInputSetSha256',verified_hash,
    'populateReceiptSha256',receipt_hash,'totalBytes',total);
  attestation_hash:=creative_craft_json_sha256(attestation_body);
  attestation_body:=attestation_body||jsonb_build_object(
    'attestationSha256',attestation_hash);
  INSERT INTO creative_craft_input_mints(
    user_id,mint_id,population_generation_id,writer_token,manifest_sha256,
    verified_input_set,verified_input_set_sha256,populate_receipt,
    populate_receipt_sha256,total_bytes,attestation,attestation_sha256)
  VALUES(p_user_id,p_mint_id,p_generation_id,p_writer_token,
    manifest_row.manifest_sha256,p_verified_input_set,verified_hash,
    p_populate_receipt,receipt_hash,total,attestation_body,attestation_hash)
  ON CONFLICT (user_id,mint_id) DO NOTHING;
  GET DIAGNOSTICS inserted=ROW_COUNT;
  SELECT * INTO stored FROM creative_craft_input_mints
   WHERE user_id=p_user_id AND mint_id=p_mint_id FOR UPDATE;
  IF (stored.population_generation_id,stored.writer_token,
      stored.verified_input_set,stored.populate_receipt,stored.attestation)
     IS DISTINCT FROM
     (p_generation_id,p_writer_token,p_verified_input_set,
      p_populate_receipt,attestation_body) THEN
    RAISE EXCEPTION 'Craft input mint retry diverged' USING ERRCODE='40001';
  END IF;
  RETURN jsonb_build_object('created',inserted=1,'attestation',stored.attestation,
    'attestationSha256',stored.attestation_sha256);
END $$;

CREATE FUNCTION creative_craft_input_cancel_request(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_request_id uuid,
  p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; intent_row record; population record; stored record;
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
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND attempt_id=p_attempt_id
   FOR UPDATE;
  IF intent_row.intent_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO population FROM creative_craft_materialization_populations
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND state IN ('claimed_unbound','writing','receipt_ready','finalizing')
   FOR UPDATE;
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
  IF population.population_generation_id IS NOT NULL THEN
    IF population.state='claimed_unbound' THEN
      UPDATE creative_craft_materialization_populations
         SET state='forgotten',writer_lease_until=NULL,
             forgotten_at=clock_timestamp(),updated_at=clock_timestamp()
       WHERE user_id=p_user_id
         AND population_generation_id=population.population_generation_id;
    ELSE
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
    'populationGenerationId',stored.population_generation_id::text);
END $$;

CREATE FUNCTION creative_craft_input_cancel_reconcile(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_request_id uuid,
  p_outcome text,p_cleanup_receipt_sha256 text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; stored record;
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
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO stored FROM creative_craft_input_cancellations
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND attempt_id=p_attempt_id AND request_id=p_request_id FOR UPDATE;
  IF stored.request_id IS NULL THEN RETURN NULL; END IF;
  IF stored.state=p_outcome AND
     stored.cleanup_receipt_sha256 IS NOT DISTINCT FROM p_cleanup_receipt_sha256
  THEN
    RETURN jsonb_build_object('requestId',p_request_id::text,
      'state',stored.state,'cleanupReceiptSha256',stored.cleanup_receipt_sha256);
  END IF;
  IF stored.state='completed' OR
     (stored.state='unknown' AND p_outcome<>'completed') THEN
    RAISE EXCEPTION 'Craft input cancel reconciliation diverged'
      USING ERRCODE='40001';
  END IF;
  UPDATE creative_craft_input_cancellations SET state=p_outcome,
    cleanup_receipt_sha256=p_cleanup_receipt_sha256,
    reconciled_at=clock_timestamp(),updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND intent_id=p_intent_id;
  RETURN jsonb_build_object('requestId',p_request_id::text,'state',p_outcome,
    'cleanupReceiptSha256',p_cleanup_receipt_sha256);
END $$;

DO $authority$
DECLARE s text:=current_schema(); binding record; input_role text;
        caller_roles text; f record;
BEGIN
  SELECT t.*,p.launcher_verifier_role,p.storage_verifier_role,
         p.receipt_definer_role,p.completion_definer_role,
         i.input_verifier_role INTO binding
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p USING(installation_key)
    JOIN creative_craft_input_installation_bindings i USING(installation_key);
  input_role:=binding.input_verifier_role;
  caller_roles:=concat_ws(',',binding.preparer_role,binding.ack_role,
    binding.escrow_role,binding.launcher_verifier_role,
    binding.storage_verifier_role,input_role);
  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
    'creative_craft_input_binding_append_only',
    'creative_craft_input_ledger_guard',
    'creative_craft_input_cancelled_population_fence',
    'creative_craft_input_exact_keys',
    'creative_craft_input_assets_current') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',
                   f.signature,caller_roles);
  END LOOP;
  EXECUTE format('ALTER FUNCTION %I.creative_craft_input_assets_current(uuid,jsonb) SET search_path TO pg_catalog,%I,pg_temp',s,s);
  FOR f IN SELECT p.oid::regprocedure signature,p.proname
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
    'creative_craft_input_require_verifier',
    'creative_craft_input_manifest_register','creative_craft_input_mint',
    'creative_craft_input_cancel_reconcile') LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.signature,
                   binding.receipt_definer_role);
    EXECUTE format('ALTER FUNCTION %s SET search_path TO pg_catalog,%I,pg_temp',
                   f.signature,s);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',
                   f.signature,caller_roles);
  END LOOP;
  -- Dynamic owner is required because every installation has a scoped role.
  EXECUTE format('ALTER FUNCTION %I.creative_craft_input_cancel_request(uuid,uuid,uuid,uuid,text) OWNER TO %I',
                 s,binding.completion_definer_role);
  EXECUTE format('ALTER FUNCTION %I.creative_craft_input_cancel_request(uuid,uuid,uuid,uuid,text) SET search_path TO pg_catalog,%I,pg_temp',s,s);
  EXECUTE format('REVOKE ALL ON FUNCTION %I.creative_craft_input_cancel_request(uuid,uuid,uuid,uuid,text) FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',s,caller_roles);
  EXECUTE format('REVOKE ALL ON %I.creative_craft_input_installation_bindings,%I.creative_craft_input_manifests,%I.creative_craft_input_mints,%I.creative_craft_input_cancellations FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',s,s,s,s,caller_roles);
  EXECUTE format('GRANT SELECT ON %I.users,%I.creative_execution_jobs,%I.creative_execution_steps,%I.creative_execution_attempts,%I.creative_craft_materialization_intents,%I.creative_craft_materialization_populations,%I.creative_craft_physical_installation_bindings,%I.creative_craft_input_installation_bindings,%I.creative_assets,%I.creative_asset_revisions,%I.creative_craft_input_manifests,%I.creative_craft_input_mints,%I.creative_craft_input_cancellations TO %I',s,s,s,s,s,s,s,s,s,s,s,s,s,binding.receipt_definer_role);
  -- PostgreSQL requires one UPDATE privilege for locking SELECTs.  These are
  -- immutable identity columns; their table guards still reject real writes.
  EXECUTE format('GRANT UPDATE(deletion_requested_at) ON %I.users TO %I',s,binding.receipt_definer_role);
  EXECUTE format('GRANT UPDATE(id) ON %I.creative_execution_jobs,%I.creative_execution_attempts,%I.creative_assets TO %I',s,s,s,binding.receipt_definer_role);
  EXECUTE format('GRANT UPDATE(step_id) ON %I.creative_execution_steps TO %I',s,binding.receipt_definer_role);
  EXECUTE format('GRANT UPDATE(intent_id) ON %I.creative_craft_materialization_intents TO %I',s,binding.receipt_definer_role);
  EXECUTE format('GRANT UPDATE(population_generation_id) ON %I.creative_craft_materialization_populations TO %I',s,binding.receipt_definer_role);
  EXECUTE format('GRANT UPDATE(asset_id) ON %I.creative_asset_revisions TO %I',s,binding.receipt_definer_role);
  EXECUTE format('GRANT UPDATE(mint_id) ON %I.creative_craft_input_manifests TO %I',s,binding.receipt_definer_role);
  EXECUTE format('GRANT UPDATE(mint_id) ON %I.creative_craft_input_mints TO %I',s,binding.receipt_definer_role);
  EXECUTE format('GRANT INSERT ON %I.creative_craft_input_manifests,%I.creative_craft_input_mints TO %I',s,s,binding.receipt_definer_role);
  EXECUTE format('GRANT INSERT,UPDATE(state,cleanup_receipt_sha256,reconciled_at,updated_at) ON %I.creative_craft_input_cancellations TO %I',s,binding.receipt_definer_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_input_exact_keys(jsonb,text[]) TO %I',s,binding.receipt_definer_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_input_assets_current(uuid,jsonb) TO %I',s,binding.receipt_definer_role);
  EXECUTE format('GRANT SELECT ON %I.creative_craft_input_cancellations,%I.creative_craft_input_manifests,%I.creative_craft_input_mints TO %I',s,s,s,binding.completion_definer_role);
  EXECUTE format('GRANT INSERT,UPDATE(state,updated_at) ON %I.creative_craft_input_cancellations TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I',s,input_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_input_manifest_register(uuid,uuid,uuid,uuid,uuid,jsonb,text),%I.creative_craft_input_mint(uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb),%I.creative_craft_input_cancel_reconcile(uuid,uuid,uuid,uuid,text,text) TO %I',s,s,s,input_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_input_cancel_request(uuid,uuid,uuid,uuid,text) TO %I',s,binding.preparer_role);
END $authority$;

DO $audit$
DECLARE s text:=current_schema(); binding record; role_row record;
        table_name text; input_role text;
BEGIN
  SELECT t.*,p.receipt_definer_role,p.completion_definer_role,
         i.input_verifier_role,i.desired_active INTO binding
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p USING(installation_key)
    JOIN creative_craft_input_installation_bindings i USING(installation_key);
  input_role:=binding.input_verifier_role;
  SELECT * INTO role_row FROM pg_roles WHERE rolname=input_role;
  IF binding.desired_active OR role_row.rolcanlogin OR role_row.rolinherit
     OR role_row.rolsuper OR role_row.rolcreatedb OR role_row.rolcreaterole
     OR role_row.rolreplication OR role_row.rolbypassrls
     OR EXISTS(SELECT 1 FROM pg_auth_members m
                WHERE m.roleid=role_row.oid OR m.member=role_row.oid) THEN
    RAISE EXCEPTION 'Craft 118 verifier role is not isolated'
      USING ERRCODE='55000';
  END IF;
  FOREACH table_name IN ARRAY ARRAY[
    'creative_craft_input_installation_bindings',
    'creative_craft_input_manifests','creative_craft_input_mints',
    'creative_craft_input_cancellations'] LOOP
    IF has_table_privilege(input_role,format('%I.%I',s,table_name),
         'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN
      RAISE EXCEPTION 'Craft 118 verifier gained direct table access: %',table_name
        USING ERRCODE='55000';
    END IF;
  END LOOP;
  IF NOT has_function_privilege(input_role,format(
       '%I.creative_craft_input_manifest_register(uuid,uuid,uuid,uuid,uuid,jsonb,text)',s),'EXECUTE')
     OR NOT has_function_privilege(input_role,format(
       '%I.creative_craft_input_mint(uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb)',s),'EXECUTE')
     OR NOT has_function_privilege(input_role,format(
       '%I.creative_craft_input_cancel_reconcile(uuid,uuid,uuid,uuid,text,text)',s),'EXECUTE')
     OR has_function_privilege('uonify_app_runtime',format(
       '%I.creative_craft_input_mint(uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb)',s),'EXECUTE') THEN
    RAISE EXCEPTION 'Craft 118 exact execute boundary is not closed'
      USING ERRCODE='55000';
  END IF;
END $audit$;
