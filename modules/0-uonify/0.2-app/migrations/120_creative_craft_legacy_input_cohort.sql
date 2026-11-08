-- Forward-only, inactive Craft legacy-cohort and plan-head authority.
--
-- Gate 120A seals already-started pre-120 Craft attempts without input
-- attestations as historical unknown evidence.  An exemption never authorizes
-- dispatch or replay.  Every provider start after this migration requires one
-- exact Gate 119 consumption and one transactionally locked current plan head.
-- No route, worker, provider, GCS, UI, voice, Live, or startup path is wired.

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
SELECT pg_advisory_xact_lock(
  hashtextextended('uonify-craft-input-legacy-cohort-v1',0));

DO $preflight$
DECLARE binding record; role_name text; relation_name text;
BEGIN
  IF to_regclass('creative_craft_input_consumption_installation_bindings')
       IS NULL
     OR to_regprocedure(
       'creative_craft_input_consume_and_provider_start(uuid,uuid,uuid)')
       IS NULL
     OR to_regclass('creative_craft_input_legacy_cohorts') IS NOT NULL
     OR to_regclass('creative_craft_input_legacy_exemptions') IS NOT NULL
     OR to_regclass('uony_creative_plan_heads') IS NOT NULL
     OR to_regclass('creative_craft_input_plan_head_consumptions') IS NOT NULL
  THEN
    RAISE EXCEPTION 'Craft 120 requires one clean 119 installation'
      USING ERRCODE='55000';
  END IF;
  SELECT c.desired_active,t.preparer_role,t.ack_role,t.escrow_role,
         p.launcher_verifier_role,p.storage_verifier_role,
         p.receipt_definer_role,p.completion_definer_role,
         i.input_verifier_role INTO binding
    FROM creative_craft_input_consumption_installation_bindings c
    JOIN creative_craft_transition_installation_bindings t
      USING(installation_key)
    JOIN creative_craft_physical_installation_bindings p
      USING(installation_key)
    JOIN creative_craft_input_installation_bindings i
      USING(installation_key)
   WHERE c.database_name=current_database()
     AND c.schema_name=current_schema();
  IF binding.preparer_role IS NULL OR binding.desired_active THEN
    RAISE EXCEPTION 'Craft 120 requires one inactive scoped installation'
      USING ERRCODE='55000';
  END IF;
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
                 OR membership.member=role_row.oid))) THEN
      RAISE EXCEPTION 'Craft 120 scoped role is contaminated: %',role_name
        USING ERRCODE='55000';
    END IF;
  END LOOP;
  FOREACH role_name IN ARRAY ARRAY[
      binding.preparer_role,binding.ack_role,binding.escrow_role,
      binding.launcher_verifier_role,binding.storage_verifier_role,
      binding.input_verifier_role] LOOP
    FOREACH relation_name IN ARRAY ARRAY[
      'users','uony_creative_plans','creative_execution_jobs',
      'creative_execution_steps','creative_execution_attempts',
      'creative_craft_input_manifests','creative_craft_input_mints',
      'creative_craft_input_attestation_consumptions'] LOOP
      IF has_table_privilege(role_name,
           format('%I.%I',current_schema(),relation_name),
           'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         OR has_any_column_privilege(role_name,
           format('%I.%I',current_schema(),relation_name),
           'SELECT,INSERT,UPDATE,REFERENCES') THEN
        RAISE EXCEPTION 'Craft 120 caller gained direct table access: % on %',
          role_name,relation_name USING ERRCODE='55000';
      END IF;
    END LOOP;
  END LOOP;
END $preflight$;

-- The locks close the migration cut: a start or plan write commits before the
-- snapshot, or waits and is governed by the new triggers afterwards.
LOCK TABLE uony_creative_plans,creative_execution_jobs,
  creative_execution_steps,creative_execution_attempts,
  creative_craft_materialization_populations,
  creative_craft_input_manifests,creative_craft_input_mints
  IN SHARE ROW EXCLUSIVE MODE;

DO $receipt_preflight$
BEGIN
  IF EXISTS(
    SELECT 1
      FROM creative_craft_input_mints mint
      JOIN creative_craft_input_manifests manifest
        ON manifest.user_id=mint.user_id AND manifest.mint_id=mint.mint_id
      JOIN creative_craft_materialization_populations population
        ON population.user_id=manifest.user_id
       AND population.population_generation_id=
           manifest.population_generation_id
     WHERE jsonb_typeof(population.plan->'inputs') IS DISTINCT FROM 'array'
        OR mint.populate_receipt->>'inputsSha256' IS DISTINCT FROM
           creative_craft_json_sha256(population.plan->'inputs')) THEN
    RAISE EXCEPTION 'Craft 120 found an input receipt outside its exact plan'
      USING ERRCODE='55000';
  END IF;
END $receipt_preflight$;

-- This trigger already exists before the migration cut.  Replacing its
-- function closes the in-flight Gate 118 case as well: an old mint call may
-- have validated its arguments before waiting on the table lock, but its
-- eventual INSERT must still pass this row boundary after Gate 120 commits.
CREATE OR REPLACE FUNCTION creative_craft_input_ledger_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE receipt_owner text; completion_owner text; population_inputs jsonb;
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
    IF TG_TABLE_NAME='creative_craft_input_mints' THEN
      SELECT population.plan->'inputs' INTO population_inputs
        FROM creative_craft_materialization_populations population
       WHERE population.user_id=NEW.user_id
         AND population.population_generation_id=
             NEW.population_generation_id;
      IF jsonb_typeof(population_inputs) IS DISTINCT FROM 'array'
         OR NOT creative_craft_input_exact_keys(
              NEW.populate_receipt,ARRAY['schemaVersion','inputsSha256'])
         OR NEW.populate_receipt->>'schemaVersion' IS DISTINCT FROM '1'
         OR NEW.populate_receipt->>'inputsSha256' IS DISTINCT FROM
              creative_craft_json_sha256(population_inputs)
         OR NEW.populate_receipt_sha256 IS DISTINCT FROM
              creative_craft_json_sha256(NEW.populate_receipt)
         OR NEW.verified_input_set->>'sinkReceiptSha256' IS DISTINCT FROM
              NEW.populate_receipt_sha256 THEN
        RAISE EXCEPTION 'Craft input receipt does not bind its exact plan'
          USING ERRCODE='22023';
      END IF;
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

CREATE TABLE uony_creative_plan_heads (
  user_id uuid NOT NULL,
  thread_id text NOT NULL,
  plan_id uuid NOT NULL,
  plan_revision integer NOT NULL CHECK (plan_revision>0),
  plan_status text NOT NULL CHECK (plan_status IN ('draft','stale')),
  source_plan_sha256 text NOT NULL
    CHECK (source_plan_sha256 ~ '^[0-9a-f]{64}$'),
  plan_created_at timestamptz NOT NULL,
  head_epoch bigint NOT NULL CHECK (head_epoch>0),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(user_id,thread_id),
  FOREIGN KEY(user_id,thread_id) REFERENCES uony_threads(user_id,id),
  FOREIGN KEY(user_id,plan_id) REFERENCES uony_creative_plans(user_id,id)
    ON DELETE CASCADE
);

INSERT INTO uony_creative_plan_heads(
  user_id,thread_id,plan_id,plan_revision,plan_status,source_plan_sha256,
  plan_created_at,head_epoch)
SELECT DISTINCT ON (plan.user_id,plan.thread_id)
  plan.user_id,plan.thread_id,plan.id,plan.revision,plan.status,
  creative_craft_json_sha256(jsonb_build_object(
    'recipe',plan.recipe,'plan',plan.plan,'skillVersion',plan.skill_version,
    'productId',plan.product_id,'productRevision',plan.product_revision)),
  plan.created_at,1
  FROM uony_creative_plans plan
 ORDER BY plan.user_id,plan.thread_id,plan.created_at DESC,plan.id DESC;

CREATE TABLE creative_craft_input_legacy_cohorts (
  cohort_id uuid PRIMARY KEY,
  installation_id uuid NOT NULL UNIQUE REFERENCES
    creative_craft_input_consumption_installation_bindings(installation_id),
  installation_key text NOT NULL UNIQUE REFERENCES
    creative_craft_input_consumption_installation_bindings(installation_key),
  database_name text NOT NULL,
  schema_name text NOT NULL,
  sealed_at timestamptz NOT NULL,
  selection_policy jsonb NOT NULL CHECK (jsonb_typeof(selection_policy)='object'),
  selection_policy_sha256 text NOT NULL
    CHECK (selection_policy_sha256 ~ '^[0-9a-f]{64}$'),
  member_count bigint NOT NULL CHECK (member_count>=0),
  member_set_sha256 text NOT NULL CHECK (member_set_sha256 ~ '^[0-9a-f]{64}$'),
  redacted_member_count bigint NOT NULL DEFAULT 0
    CHECK (redacted_member_count>=0),
  redaction_epoch bigint NOT NULL DEFAULT 0 CHECK (redaction_epoch>=0),
  last_redacted_at timestamptz,
  contract_version text NOT NULL CHECK (contract_version='gate120a-v1'),
  desired_active boolean NOT NULL DEFAULT false CHECK (NOT desired_active),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK ((redaction_epoch=0)=(last_redacted_at IS NULL)),
  UNIQUE(database_name,schema_name)
);

CREATE TABLE creative_craft_input_legacy_exemptions (
  user_id uuid NOT NULL,
  exemption_id uuid NOT NULL UNIQUE,
  cohort_id uuid NOT NULL REFERENCES creative_craft_input_legacy_cohorts(cohort_id),
  attempt_id uuid NOT NULL,
  job_id uuid NOT NULL,
  step_id uuid NOT NULL,
  attempt_no integer NOT NULL CHECK (attempt_no>0),
  claim_lease_token uuid NOT NULL,
  fence_epoch bigint NOT NULL CHECK (fence_epoch>0),
  admission_id uuid NOT NULL,
  admission_sha256 text NOT NULL CHECK (admission_sha256 ~ '^[0-9a-f]{64}$'),
  claim_set_sha256 text NOT NULL CHECK (claim_set_sha256 ~ '^[0-9a-f]{64}$'),
  execution_graph_sha256 text NOT NULL
    CHECK (execution_graph_sha256 ~ '^[0-9a-f]{64}$'),
  attempt_provider_started_at timestamptz NOT NULL,
  step_provider_started_at timestamptz,
  start_shape text NOT NULL CHECK (start_shape IN ('attempt_only','both_equal')),
  consumption_disposition text NOT NULL CHECK (consumption_disposition='unknown'),
  dispatch_authorized boolean NOT NULL CHECK (NOT dispatch_authorized),
  replay_authorized boolean NOT NULL CHECK (NOT replay_authorized),
  evidence jsonb NOT NULL CHECK (jsonb_typeof(evidence)='object'),
  evidence_sha256 text NOT NULL CHECK (evidence_sha256 ~ '^[0-9a-f]{64}$'),
  exempted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(user_id,attempt_id),
  FOREIGN KEY(user_id,job_id,step_id,attempt_no,attempt_id,claim_lease_token,
      fence_epoch,admission_id,admission_sha256,claim_set_sha256)
    REFERENCES creative_execution_attempts(
      user_id,job_id,step_id,attempt_no,id,claim_lease_token,fence_epoch,
      admission_id,admission_sha256,claim_set_sha256),
  CHECK ((start_shape='attempt_only' AND step_provider_started_at IS NULL)
      OR (start_shape='both_equal'
          AND step_provider_started_at=attempt_provider_started_at))
);

CREATE TABLE creative_craft_input_plan_head_consumptions (
  user_id uuid NOT NULL,
  attempt_id uuid NOT NULL,
  consumption_id uuid NOT NULL UNIQUE REFERENCES
    creative_craft_input_attestation_consumptions(consumption_id),
  plan_id uuid NOT NULL,
  thread_id text NOT NULL,
  plan_revision integer NOT NULL CHECK (plan_revision>0),
  head_epoch bigint NOT NULL CHECK (head_epoch>0),
  source_plan_sha256 text NOT NULL
    CHECK (source_plan_sha256 ~ '^[0-9a-f]{64}$'),
  provider_started_at timestamptz NOT NULL,
  evidence jsonb NOT NULL CHECK (jsonb_typeof(evidence)='object'),
  evidence_sha256 text NOT NULL CHECK (evidence_sha256 ~ '^[0-9a-f]{64}$'),
  bound_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(user_id,attempt_id),
  FOREIGN KEY(user_id,attempt_id)
    REFERENCES creative_craft_input_attestation_consumptions(user_id,attempt_id),
  FOREIGN KEY(user_id,plan_id) REFERENCES uony_creative_plans(user_id,id),
  FOREIGN KEY(user_id,thread_id) REFERENCES uony_creative_plan_heads(user_id,thread_id)
);

DO $seal_legacy$
DECLARE binding record; cohort uuid:=gen_random_uuid(); sealed timestamptz;
        policy_body jsonb;
BEGIN
  sealed:=clock_timestamp();
  SELECT c.installation_id,c.installation_key,c.database_name,c.schema_name
    INTO binding
    FROM creative_craft_input_consumption_installation_bindings c;

  IF EXISTS(
      SELECT 1 FROM creative_execution_steps step
       WHERE step.kind='craft' AND step.provider_call
         AND step.provider_started_at IS NOT NULL
         AND NOT EXISTS(
           SELECT 1 FROM creative_execution_attempts attempt
            WHERE attempt.user_id=step.user_id AND attempt.job_id=step.job_id
              AND attempt.step_id=step.step_id
              AND attempt.provider_started_at=step.provider_started_at))
     OR EXISTS(
      SELECT 1 FROM creative_execution_attempts attempt
      JOIN creative_execution_steps step
        ON step.user_id=attempt.user_id AND step.job_id=attempt.job_id
       AND step.step_id=attempt.step_id
       WHERE step.kind='craft' AND step.provider_call
         AND attempt.provider_started_at IS NOT NULL
         AND step.provider_started_at IS NOT NULL
         AND step.provider_started_at<>attempt.provider_started_at)
  THEN
    RAISE EXCEPTION 'Craft 120 refuses ambiguous historical provider start'
      USING ERRCODE='55000';
  END IF;

  IF EXISTS(
      SELECT 1 FROM creative_craft_input_manifests manifest
      JOIN creative_execution_attempts attempt
        ON attempt.user_id=manifest.user_id AND attempt.id=manifest.attempt_id
      LEFT JOIN creative_craft_input_attestation_consumptions consumption
        ON consumption.user_id=manifest.user_id
       AND consumption.attempt_id=manifest.attempt_id
       WHERE attempt.provider_started_at IS NOT NULL
         AND consumption.consumption_id IS NULL)
     OR EXISTS(
      SELECT 1 FROM creative_craft_input_attestation_consumptions consumption
      LEFT JOIN creative_craft_input_manifests manifest
        ON manifest.user_id=consumption.user_id
       AND manifest.mint_id=consumption.mint_id
       AND manifest.attempt_id=consumption.attempt_id
       WHERE manifest.mint_id IS NULL)
  THEN
    RAISE EXCEPTION 'Craft 120 refuses incomplete input consumption evidence'
      USING ERRCODE='55000';
  END IF;

  policy_body:=jsonb_build_object(
    'schemaVersion',1,'policyId','craft-legacy-input-cohort-v1',
    'cut','migration-transaction','historicalStartsOnly',true,
    'requiresNoManifest',true,'requiresNoConsumption',true,
    'dispatchAuthorized',false,'replayAuthorized',false,
    'futureMembershipAllowed',false);
  INSERT INTO creative_craft_input_legacy_cohorts(
    cohort_id,installation_id,installation_key,database_name,schema_name,
    sealed_at,selection_policy,selection_policy_sha256,member_count,
    member_set_sha256,contract_version)
  VALUES(cohort,binding.installation_id,binding.installation_key,
    binding.database_name,binding.schema_name,sealed,policy_body,
    creative_craft_json_sha256(policy_body),0,
    creative_craft_json_sha256('[]'::jsonb),'gate120a-v1');

  WITH candidates AS (
    SELECT attempt.*,step.provider_started_at AS step_started,
           job.execution_graph_sha256
      FROM creative_execution_attempts attempt
      JOIN creative_execution_steps step
        ON step.user_id=attempt.user_id AND step.job_id=attempt.job_id
       AND step.step_id=attempt.step_id
      JOIN creative_execution_jobs job
        ON job.user_id=attempt.user_id AND job.id=attempt.job_id
      LEFT JOIN creative_craft_input_manifests manifest
        ON manifest.user_id=attempt.user_id AND manifest.attempt_id=attempt.id
      LEFT JOIN creative_craft_input_attestation_consumptions consumption
        ON consumption.user_id=attempt.user_id
       AND consumption.attempt_id=attempt.id
     WHERE step.kind='craft' AND step.provider_call
       AND attempt.provider_started_at IS NOT NULL
       AND manifest.mint_id IS NULL AND consumption.consumption_id IS NULL
  ), identities AS (
    SELECT candidate.*,gen_random_uuid() AS exemption_id
      FROM candidates candidate
  ), evidence_rows AS (
    SELECT identity.*,jsonb_build_object(
      'schemaVersion',1,'status','legacy_exempted',
      'exemptionId',identity.exemption_id::text,'cohortId',cohort::text,
      'installationId',binding.installation_id::text,
      'userId',identity.user_id::text,'attemptId',identity.id::text,
      'jobId',identity.job_id::text,'stepId',identity.step_id::text,
      'attemptNo',identity.attempt_no,
      'claimLeaseTokenSha256',creative_craft_json_sha256(
        to_jsonb(identity.claim_lease_token::text)),
      'fenceEpoch',identity.fence_epoch,'admissionId',identity.admission_id::text,
      'admissionSha256',identity.admission_sha256,
      'claimSetSha256',identity.claim_set_sha256,
      'executionGraphSha256',identity.execution_graph_sha256,
      'attemptProviderStartedAt',to_char(
        identity.provider_started_at AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'stepProviderStartedAt',CASE WHEN identity.step_started IS NULL THEN NULL
        ELSE to_jsonb(to_char(identity.step_started AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')) END,
      'startShape',CASE WHEN identity.step_started IS NULL
        THEN 'attempt_only' ELSE 'both_equal' END,
      'consumptionState','unknown','dispatchAuthorized',false,
      'replayAuthorized',false) AS evidence_body
      FROM identities identity
  )
  INSERT INTO creative_craft_input_legacy_exemptions(
    user_id,exemption_id,cohort_id,attempt_id,job_id,step_id,attempt_no,
    claim_lease_token,fence_epoch,admission_id,admission_sha256,
    claim_set_sha256,execution_graph_sha256,attempt_provider_started_at,
    step_provider_started_at,start_shape,consumption_disposition,
    dispatch_authorized,replay_authorized,evidence,evidence_sha256,exempted_at)
  SELECT user_id,exemption_id,cohort,id,job_id,step_id,attempt_no,
    claim_lease_token,fence_epoch,admission_id,admission_sha256,
    claim_set_sha256,execution_graph_sha256,provider_started_at,step_started,
    CASE WHEN step_started IS NULL THEN 'attempt_only' ELSE 'both_equal' END,
    'unknown',false,false,evidence_body,
    creative_craft_json_sha256(evidence_body),sealed
    FROM evidence_rows;

  UPDATE creative_craft_input_legacy_cohorts SET
    member_count=(SELECT count(*) FROM creative_craft_input_legacy_exemptions
                   WHERE cohort_id=cohort),
    member_set_sha256=creative_craft_json_sha256(coalesce((
      SELECT jsonb_agg(evidence ORDER BY user_id,attempt_id)
        FROM creative_craft_input_legacy_exemptions
       WHERE cohort_id=cohort),'[]'::jsonb))
   WHERE cohort_id=cohort;
END $seal_legacy$;

CREATE FUNCTION creative_craft_input_legacy_cohort_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE expected_role text; expected_count bigint; expected_hash text;
BEGIN
  IF TG_OP='UPDATE' AND current_setting('uonify.deleting_user',true) IS NOT NULL THEN
    SELECT completion_definer_role INTO expected_role
      FROM creative_craft_physical_installation_bindings;
    SELECT count(*),creative_craft_json_sha256(coalesce(
      jsonb_agg(evidence ORDER BY user_id,attempt_id),'[]'::jsonb))
      INTO expected_count,expected_hash
      FROM creative_craft_input_legacy_exemptions
     WHERE cohort_id=OLD.cohort_id;
    IF current_user=expected_role
       AND (NEW.cohort_id,NEW.installation_id,NEW.installation_key,
            NEW.database_name,NEW.schema_name,NEW.sealed_at,
            NEW.selection_policy,NEW.selection_policy_sha256,
            NEW.contract_version,NEW.desired_active,NEW.created_at)
           IS NOT DISTINCT FROM
           (OLD.cohort_id,OLD.installation_id,OLD.installation_key,
            OLD.database_name,OLD.schema_name,OLD.sealed_at,
            OLD.selection_policy,OLD.selection_policy_sha256,
            OLD.contract_version,OLD.desired_active,OLD.created_at)
       AND NEW.member_count=expected_count
       AND NEW.member_set_sha256=expected_hash
       AND NEW.redacted_member_count=
             OLD.redacted_member_count+(OLD.member_count-NEW.member_count)
       AND NEW.redaction_epoch=OLD.redaction_epoch+1
       AND NEW.last_redacted_at IS NOT NULL
       AND NEW.member_count<=OLD.member_count THEN
      RETURN NEW;
    END IF;
  END IF;
  RAISE EXCEPTION 'Craft legacy input cohort is sealed'
    USING ERRCODE='55000';
END $$;
CREATE TRIGGER creative_craft_input_legacy_cohort_guard
BEFORE INSERT OR UPDATE OR DELETE ON creative_craft_input_legacy_cohorts
FOR EACH ROW EXECUTE FUNCTION creative_craft_input_legacy_cohort_guard();

CREATE FUNCTION creative_craft_input_legacy_exemption_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP='DELETE'
     AND current_setting('uonify.deleting_user',true)=OLD.user_id::text THEN
    PERFORM pg_advisory_xact_lock(
      hashtextextended('uonify:account:'||OLD.user_id::text,0));
    IF EXISTS(SELECT 1 FROM users WHERE id=OLD.user_id
              AND deletion_requested_at IS NOT NULL FOR NO KEY UPDATE) THEN
      RETURN OLD;
    END IF;
  END IF;
  RAISE EXCEPTION 'Craft legacy input exemption is sealed'
    USING ERRCODE='42501';
END $$;
CREATE TRIGGER creative_craft_input_legacy_exemption_guard
BEFORE INSERT OR UPDATE OR DELETE ON creative_craft_input_legacy_exemptions
FOR EACH ROW EXECUTE FUNCTION creative_craft_input_legacy_exemption_guard();

CREATE FUNCTION creative_craft_input_legacy_exemption_redact()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE deleting_user text:=current_setting('uonify.deleting_user',true);
BEGIN
  IF deleting_user IS NULL
     OR EXISTS(SELECT 1 FROM deleted_exemptions
                WHERE user_id::text<>deleting_user) THEN
    RAISE EXCEPTION 'Craft legacy redaction requires exact account deletion'
      USING ERRCODE='42501';
  END IF;
  UPDATE creative_craft_input_legacy_cohorts cohort SET
    member_count=(SELECT count(*)
      FROM creative_craft_input_legacy_exemptions retained
      WHERE retained.cohort_id=cohort.cohort_id),
    member_set_sha256=creative_craft_json_sha256(coalesce((
      SELECT jsonb_agg(evidence ORDER BY user_id,attempt_id)
        FROM creative_craft_input_legacy_exemptions retained
       WHERE retained.cohort_id=cohort.cohort_id),'[]'::jsonb)),
    redacted_member_count=cohort.redacted_member_count+
      (SELECT count(*) FROM deleted_exemptions deleted
        WHERE deleted.cohort_id=cohort.cohort_id),
    redaction_epoch=cohort.redaction_epoch+1,
    last_redacted_at=clock_timestamp()
   WHERE cohort.cohort_id IN (
     SELECT DISTINCT cohort_id FROM deleted_exemptions);
  RETURN NULL;
END $$;
CREATE TRIGGER creative_craft_input_legacy_exemption_redact
AFTER DELETE ON creative_craft_input_legacy_exemptions
REFERENCING OLD TABLE AS deleted_exemptions
FOR EACH STATEMENT EXECUTE FUNCTION
  creative_craft_input_legacy_exemption_redact();

CREATE FUNCTION creative_craft_input_plan_head_ledger_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE expected_role text;
BEGIN
  IF TG_OP='DELETE'
     AND current_setting('uonify.deleting_user',true)=OLD.user_id::text THEN
    PERFORM pg_advisory_xact_lock(
      hashtextextended('uonify:account:'||OLD.user_id::text,0));
    IF EXISTS(SELECT 1 FROM users WHERE id=OLD.user_id
              AND deletion_requested_at IS NOT NULL FOR NO KEY UPDATE) THEN
      RETURN OLD;
    END IF;
  END IF;
  -- A plan head is a derived pointer.  PostgreSQL's FK cascade reaches this
  -- trigger only after the parent plan is gone.  The independent consumption
  -- FK still prevents deletion of any plan already used for provider start.
  IF TG_OP='DELETE' AND TG_TABLE_NAME='uony_creative_plan_heads'
     AND NOT EXISTS(
       SELECT 1 FROM uony_creative_plans plan
        WHERE plan.user_id=OLD.user_id AND plan.id=OLD.plan_id) THEN
    RETURN OLD;
  END IF;
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'Craft plan-head ledger is deleted only with its account'
      USING ERRCODE='42501';
  END IF;
  SELECT completion_definer_role INTO expected_role
    FROM creative_craft_physical_installation_bindings;
  IF current_user<>expected_role THEN
    RAISE EXCEPTION 'Craft plan-head ledger requires scoped authority'
      USING ERRCODE='42501';
  END IF;
  IF TG_TABLE_NAME='creative_craft_input_plan_head_consumptions'
     AND TG_OP<>'INSERT' THEN
    RAISE EXCEPTION 'Craft plan-head consumption is append-only'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER uony_creative_plan_head_guard
BEFORE INSERT OR UPDATE OR DELETE ON uony_creative_plan_heads
FOR EACH ROW EXECUTE FUNCTION creative_craft_input_plan_head_ledger_guard();
CREATE TRIGGER creative_craft_input_plan_head_consumption_guard
BEFORE INSERT OR UPDATE OR DELETE
ON creative_craft_input_plan_head_consumptions
FOR EACH ROW EXECUTE FUNCTION creative_craft_input_plan_head_ledger_guard();

CREATE FUNCTION creative_craft_plan_identity_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.user_id,NEW.id,NEW.google_subject,NEW.project_id,NEW.thread_id,
      NEW.origin_request_id,NEW.created_at) IS DISTINCT FROM
     (OLD.user_id,OLD.id,OLD.google_subject,OLD.project_id,OLD.thread_id,
      OLD.origin_request_id,OLD.created_at) THEN
    RAISE EXCEPTION 'Creative plan identity and ordering are immutable'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER creative_craft_plan_identity_guard
BEFORE UPDATE OF user_id,id,google_subject,project_id,thread_id,
  origin_request_id,created_at ON uony_creative_plans
FOR EACH ROW EXECUTE FUNCTION creative_craft_plan_identity_guard();

CREATE FUNCTION creative_craft_plan_head_sync()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF TG_OP='INSERT' THEN
    INSERT INTO uony_creative_plan_heads(
      user_id,thread_id,plan_id,plan_revision,plan_status,source_plan_sha256,
      plan_created_at,head_epoch,updated_at)
    VALUES(NEW.user_id,NEW.thread_id,NEW.id,NEW.revision,NEW.status,
      creative_craft_json_sha256(jsonb_build_object(
        'recipe',NEW.recipe,'plan',NEW.plan,'skillVersion',NEW.skill_version,
        'productId',NEW.product_id,'productRevision',NEW.product_revision)),
      NEW.created_at,1,clock_timestamp())
    ON CONFLICT(user_id,thread_id) DO UPDATE SET
      plan_id=EXCLUDED.plan_id,plan_revision=EXCLUDED.plan_revision,
      plan_status=EXCLUDED.plan_status,
      source_plan_sha256=EXCLUDED.source_plan_sha256,
      plan_created_at=EXCLUDED.plan_created_at,
      head_epoch=uony_creative_plan_heads.head_epoch+1,
      updated_at=clock_timestamp()
    WHERE (EXCLUDED.plan_created_at,EXCLUDED.plan_id)>
          (uony_creative_plan_heads.plan_created_at,
           uony_creative_plan_heads.plan_id);
  ELSE
    UPDATE uony_creative_plan_heads SET plan_revision=NEW.revision,
      plan_status=NEW.status,
      source_plan_sha256=creative_craft_json_sha256(jsonb_build_object(
        'recipe',NEW.recipe,'plan',NEW.plan,'skillVersion',NEW.skill_version,
        'productId',NEW.product_id,'productRevision',NEW.product_revision)),
      head_epoch=head_epoch+1,updated_at=clock_timestamp()
     WHERE user_id=NEW.user_id AND thread_id=NEW.thread_id
       AND plan_id=NEW.id
       AND (plan_revision,plan_status,source_plan_sha256) IS DISTINCT FROM
           (NEW.revision,NEW.status,creative_craft_json_sha256(
             jsonb_build_object(
               'recipe',NEW.recipe,'plan',NEW.plan,
               'skillVersion',NEW.skill_version,'productId',NEW.product_id,
               'productRevision',NEW.product_revision)));
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER creative_craft_plan_head_sync
AFTER INSERT OR UPDATE OF revision,status,recipe,plan,skill_version,
  product_id,product_revision ON uony_creative_plans
FOR EACH ROW EXECUTE FUNCTION creative_craft_plan_head_sync();

-- Zero-input Craft jobs are still attested: the exact empty manifest,
-- empty descriptor observation set, zero-byte receipt, plan head and one-use
-- consumption are all bound before provider start.  This supports procedural
-- EffectCraft jobs without weakening any non-empty asset verification.
CREATE OR REPLACE FUNCTION creative_craft_input_assets_current(
  p_user_id uuid,p_manifest jsonb) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE mismatch boolean;
BEGIN
  IF jsonb_typeof(p_manifest)<>'object'
     OR jsonb_typeof(p_manifest->'entries')<>'array' THEN
    RETURN false;
  END IF;
  IF jsonb_array_length(p_manifest->'entries')=0 THEN
    RETURN true;
  END IF;
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

CREATE OR REPLACE FUNCTION creative_craft_input_manifest_register(
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
  IF entry_count>(binding.policy->>'maxInputs')::integer
     OR (entry_count=0 AND (
          attempt_row.craft_resolved_job_snapshot#>>'{engine,name}'
            IS DISTINCT FROM 'effectcraft'
          OR attempt_row.craft_resolved_job_snapshot->>'operation'
            IS DISTINCT FROM 'motion_graphics'))
     OR jsonb_typeof(population.plan->'inputs') IS DISTINCT FROM 'array'
     OR jsonb_typeof(attempt_row.craft_resolved_job_snapshot->'inputs')
          IS DISTINCT FROM 'array'
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
  IF (entry_count>0 AND coalesce(mismatch,true))
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

CREATE OR REPLACE FUNCTION creative_craft_input_mint(
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
     OR jsonb_typeof(population.plan->'inputs') IS DISTINCT FROM 'array'
     OR p_populate_receipt->>'inputsSha256' IS DISTINCT FROM
          creative_craft_json_sha256(population.plan->'inputs')
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
  IF (jsonb_array_length(manifest_row.manifest->'entries')>0
      AND coalesce(mismatch,true))
     OR total<>(p_verified_input_set->>'totalBytes')::bigint
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

CREATE FUNCTION creative_craft_input_start_consumption_exact(
  p_user_id uuid,p_attempt_id uuid,p_provider_started_at timestamptz)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE proof record;
BEGIN
  IF p_user_id IS NULL OR p_attempt_id IS NULL
     OR p_provider_started_at IS NULL THEN RETURN false; END IF;
  SELECT consumption.*,attempt.job_id AS current_job_id,
         attempt.step_id AS current_step_id,
         attempt.attempt_no AS current_attempt_no,
         attempt.claim_lease_token AS current_claim_lease_token,
         attempt.fence_epoch AS current_fence_epoch,
         attempt.admission_sha256 AS current_admission_sha256,
         attempt.claim_set_sha256 AS current_claim_set_sha256,
         manifest.manifest,manifest.manifest_sha256 AS current_manifest_sha256,
         manifest.plan_sha256 AS current_plan_sha256,
         manifest.population_fence_sha256 AS current_population_fence_sha256,
         mint.attestation_sha256 AS current_attestation_sha256,
         mint.verified_input_set_sha256 AS current_verified_set_sha256,
         mint.populate_receipt_sha256 AS current_populate_receipt_sha256,
         population.state AS population_state,intent.state AS intent_state,
         reservation.compensation_status,reservation.reserved_at
    INTO proof
    FROM creative_craft_input_attestation_consumptions consumption
    JOIN creative_execution_attempts attempt
      ON attempt.user_id=consumption.user_id
     AND attempt.id=consumption.attempt_id
    JOIN creative_craft_input_manifests manifest
      ON manifest.user_id=consumption.user_id
     AND manifest.mint_id=consumption.mint_id
     AND manifest.attempt_id=consumption.attempt_id
     AND manifest.intent_id=consumption.intent_id
     AND manifest.population_generation_id=
         consumption.population_generation_id
    JOIN creative_craft_input_mints mint
      ON mint.user_id=consumption.user_id
     AND mint.mint_id=consumption.mint_id
     AND mint.population_generation_id=consumption.population_generation_id
    JOIN creative_craft_materialization_populations population
      ON population.user_id=consumption.user_id
     AND population.attempt_id=consumption.attempt_id
     AND population.intent_id=consumption.intent_id
     AND population.population_generation_id=
         consumption.population_generation_id
    JOIN creative_craft_materialization_intents intent
      ON intent.user_id=consumption.user_id
     AND intent.attempt_id=consumption.attempt_id
     AND intent.intent_id=consumption.intent_id
    JOIN creative_craft_launcher_reservations reservation
      ON reservation.user_id=consumption.user_id
     AND reservation.attempt_id=consumption.attempt_id
     AND reservation.materialization_intent_id=consumption.intent_id
     AND reservation.materialization_generation_id=
         consumption.population_generation_id
   WHERE consumption.user_id=p_user_id
     AND consumption.attempt_id=p_attempt_id
     AND consumption.provider_started_at=p_provider_started_at;
  IF proof.consumption_id IS NULL
     OR proof.job_id<>proof.current_job_id
     OR proof.step_id<>proof.current_step_id
     OR proof.attempt_no<>proof.current_attempt_no
     OR proof.claim_lease_token<>proof.current_claim_lease_token
     OR proof.fence_epoch<>proof.current_fence_epoch
     OR proof.admission_sha256<>proof.current_admission_sha256
     OR proof.claim_set_sha256<>proof.current_claim_set_sha256
     OR proof.manifest_sha256<>proof.current_manifest_sha256
     OR proof.plan_sha256<>proof.current_plan_sha256
     OR proof.population_fence_sha256<>proof.current_population_fence_sha256
     OR proof.attestation_sha256<>proof.current_attestation_sha256
     OR proof.verified_input_set_sha256<>proof.current_verified_set_sha256
     OR proof.populate_receipt_sha256<>proof.current_populate_receipt_sha256
     OR proof.population_state<>'attached' OR proof.intent_state<>'attached'
     OR proof.compensation_status<>'confirmed' OR proof.reserved_at IS NULL
     OR EXISTS(SELECT 1 FROM creative_craft_input_cancellations cancellation
          WHERE cancellation.user_id=p_user_id
            AND cancellation.intent_id=proof.intent_id)
     OR NOT creative_craft_input_assets_current(p_user_id,proof.manifest)
  THEN RETURN false; END IF;
  RETURN true;
END $$;

CREATE FUNCTION creative_craft_input_plan_head_bind(
  p_user_id uuid,p_attempt_id uuid,p_provider_started_at timestamptz)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE head_row record; consumed record; body jsonb; body_hash text;
BEGIN
  IF NOT creative_craft_input_start_consumption_exact(
      p_user_id,p_attempt_id,p_provider_started_at) THEN RETURN false; END IF;
  SELECT head.*,quote.plan_id AS quoted_plan_id,
         quote.plan_revision AS quoted_plan_revision,
         quote.thread_id AS quoted_thread_id,
         quote.source_plan_sha256 AS quoted_source_plan_sha256,
         consumption.consumption_id
    INTO head_row
    FROM creative_craft_input_attestation_consumptions consumption
    JOIN creative_execution_jobs job
      ON job.user_id=consumption.user_id AND job.id=consumption.job_id
    JOIN creative_execution_approvals approval
      ON approval.user_id=job.user_id AND approval.id=job.approval_id
    JOIN creative_execution_quotes quote
      ON quote.user_id=approval.user_id AND quote.id=approval.quote_id
    JOIN uony_creative_plan_heads head
      ON head.user_id=quote.user_id AND head.thread_id=quote.thread_id
   WHERE consumption.user_id=p_user_id
     AND consumption.attempt_id=p_attempt_id
     AND consumption.provider_started_at=p_provider_started_at
   FOR SHARE OF head;
  IF head_row.consumption_id IS NULL
     OR head_row.plan_id<>head_row.quoted_plan_id
     OR head_row.plan_revision<>head_row.quoted_plan_revision
     OR head_row.thread_id<>head_row.quoted_thread_id
     OR head_row.plan_status<>'draft'
     OR head_row.source_plan_sha256<>head_row.quoted_source_plan_sha256
  THEN RETURN false; END IF;
  body:=jsonb_build_object(
    'schemaVersion',1,'status','plan_head_bound',
    'consumptionId',head_row.consumption_id::text,
    'attemptId',p_attempt_id::text,'planId',head_row.plan_id::text,
    'threadId',head_row.thread_id,'planRevision',head_row.plan_revision,
    'headEpoch',head_row.head_epoch,
    'sourcePlanSha256',head_row.source_plan_sha256,
    'providerStartedAt',to_char(p_provider_started_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
  body_hash:=creative_craft_json_sha256(body);
  INSERT INTO creative_craft_input_plan_head_consumptions(
    user_id,attempt_id,consumption_id,plan_id,thread_id,plan_revision,
    head_epoch,source_plan_sha256,provider_started_at,evidence,evidence_sha256)
  VALUES(p_user_id,p_attempt_id,head_row.consumption_id,head_row.plan_id,
    head_row.thread_id,head_row.plan_revision,head_row.head_epoch,
    head_row.source_plan_sha256,p_provider_started_at,body,body_hash)
  ON CONFLICT(user_id,attempt_id) DO NOTHING;
  SELECT * INTO consumed FROM creative_craft_input_plan_head_consumptions
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id;
  RETURN coalesce(consumed.consumption_id=head_row.consumption_id
     AND consumed.plan_id=head_row.plan_id
     AND consumed.plan_revision=head_row.plan_revision
     AND consumed.head_epoch=head_row.head_epoch
     AND consumed.source_plan_sha256=head_row.source_plan_sha256
     AND consumed.provider_started_at=p_provider_started_at
     AND consumed.evidence=body AND consumed.evidence_sha256=body_hash,false);
END $$;

CREATE OR REPLACE FUNCTION creative_craft_provider_start_requires_materialization()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.provider_started_at IS NOT NULL AND OLD.provider_started_at IS NULL
     AND EXISTS(SELECT 1 FROM creative_execution_steps step
       JOIN creative_execution_jobs job
         ON job.user_id=step.user_id AND job.id=step.job_id
      WHERE step.user_id=NEW.user_id AND step.job_id=NEW.job_id
        AND step.step_id=NEW.step_id AND step.kind='craft'
        AND coalesce((job.graph_snapshot->>'schemaVersion')::integer,1)>=2)
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
  IF NEW.provider_started_at IS NOT NULL AND OLD.provider_started_at IS NULL
     AND EXISTS(SELECT 1 FROM creative_execution_steps step
       WHERE step.user_id=NEW.user_id AND step.job_id=NEW.job_id
         AND step.step_id=NEW.step_id AND step.kind='craft'
         AND step.provider_call)
     AND NOT creative_craft_input_plan_head_bind(
       NEW.user_id,NEW.id,NEW.provider_started_at) THEN
    RAISE EXCEPTION 'Craft provider start requires exact input consumption and plan head'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION
  creative_craft_step_provider_start_requires_input_consumption()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE resolved_attempt_id uuid; attempt_count integer;
BEGIN
  IF NEW.provider_started_at IS NOT NULL AND OLD.provider_started_at IS NULL
     AND NEW.kind='craft' AND NEW.provider_call THEN
    SELECT count(*),(array_agg(attempt.id ORDER BY attempt.attempt_no DESC))[1]
      INTO attempt_count,resolved_attempt_id
      FROM creative_execution_attempts attempt
     WHERE attempt.user_id=NEW.user_id AND attempt.job_id=NEW.job_id
       AND attempt.step_id=NEW.step_id
       AND attempt.provider_started_at=NEW.provider_started_at;
    IF attempt_count<>1
       OR NOT creative_craft_input_start_consumption_exact(
            NEW.user_id,resolved_attempt_id,NEW.provider_started_at)
       OR NOT EXISTS(
         SELECT 1 FROM creative_craft_input_plan_head_consumptions bound
         JOIN creative_craft_input_attestation_consumptions consumption
           ON consumption.user_id=bound.user_id
          AND consumption.consumption_id=bound.consumption_id
        WHERE bound.user_id=NEW.user_id
          AND bound.attempt_id=resolved_attempt_id
          AND bound.provider_started_at=NEW.provider_started_at
          AND consumption.attempt_id=resolved_attempt_id
          AND consumption.provider_started_at=NEW.provider_started_at)
    THEN
      RAISE EXCEPTION 'Craft step start requires exact input consumption and plan head'
        USING ERRCODE='55000';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE FUNCTION creative_craft_input_legacy_exemption_status(
  p_user_id uuid,p_attempt_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; exemption record;
BEGIN
  PERFORM creative_craft_input_require_verifier();
  IF p_user_id IS NULL OR p_attempt_id IS NULL THEN
    RAISE EXCEPTION 'Craft legacy exemption identity is not closed'
      USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR owner_row.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(
    creative_craft_attempt_advisory_key(p_attempt_id));
  PERFORM 1 FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO exemption FROM creative_craft_input_legacy_exemptions
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id;
  IF exemption.exemption_id IS NULL THEN RETURN NULL; END IF;
  IF exemption.evidence_sha256<>creative_craft_json_sha256(exemption.evidence)
     OR exemption.evidence->>'status'<>'legacy_exempted'
     OR exemption.evidence->>'dispatchAuthorized'<>'false'
     OR exemption.evidence->>'replayAuthorized'<>'false' THEN
    RAISE EXCEPTION 'Craft legacy exemption evidence is corrupt'
      USING ERRCODE='55000';
  END IF;
  RETURN exemption.evidence;
END $$;

DO $authority$
DECLARE s text:=current_schema(); binding record; caller_roles text; f record;
        role_name text; relation_name text;
BEGIN
  SELECT t.*,p.receipt_definer_role,p.completion_definer_role,
         p.launcher_verifier_role,p.storage_verifier_role,
         i.input_verifier_role INTO binding
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p USING(installation_key)
    JOIN creative_craft_input_installation_bindings i USING(installation_key);
  caller_roles:=concat_ws(',',binding.preparer_role,binding.ack_role,
    binding.escrow_role,binding.launcher_verifier_role,
    binding.storage_verifier_role,binding.input_verifier_role);

  FOR f IN SELECT procedure.oid::regprocedure signature
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
   WHERE namespace.nspname=s AND procedure.proname IN (
    'creative_craft_input_ledger_guard',
    'creative_craft_input_legacy_cohort_guard',
    'creative_craft_input_legacy_exemption_guard',
    'creative_craft_input_legacy_exemption_redact',
    'creative_craft_input_plan_head_ledger_guard',
    'creative_craft_plan_identity_guard',
    'creative_craft_plan_head_sync',
    'creative_craft_input_start_consumption_exact',
    'creative_craft_input_plan_head_bind',
    'creative_craft_provider_start_requires_materialization',
    'creative_craft_step_provider_start_requires_input_consumption') LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.signature,
      binding.completion_definer_role);
    EXECUTE format('ALTER FUNCTION %s SET search_path TO pg_catalog,%I,pg_temp',
      f.signature,s);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',
      f.signature,caller_roles);
  END LOOP;
  EXECUTE format('ALTER FUNCTION %I.creative_craft_input_assets_current(uuid,jsonb) SET search_path TO pg_catalog,%I,pg_temp',s,s);
  EXECUTE format('REVOKE ALL ON FUNCTION %I.creative_craft_input_assets_current(uuid,jsonb) FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',s,caller_roles);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_input_assets_current(uuid,jsonb) TO %I,%I',s,binding.receipt_definer_role,binding.completion_definer_role);
  FOR f IN SELECT procedure.oid::regprocedure signature
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
   WHERE namespace.nspname=s AND procedure.proname IN (
    'creative_craft_input_manifest_register','creative_craft_input_mint') LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.signature,
      binding.receipt_definer_role);
    EXECUTE format('ALTER FUNCTION %s SET search_path TO pg_catalog,%I,pg_temp',
      f.signature,s);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',
      f.signature,caller_roles);
  END LOOP;
  EXECUTE format('ALTER FUNCTION %I.creative_craft_input_legacy_exemption_status(uuid,uuid) OWNER TO %I',s,binding.receipt_definer_role);
  EXECUTE format('ALTER FUNCTION %I.creative_craft_input_legacy_exemption_status(uuid,uuid) SET search_path TO pg_catalog,%I,pg_temp',s,s);
  EXECUTE format('REVOKE ALL ON FUNCTION %I.creative_craft_input_legacy_exemption_status(uuid,uuid) FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',s,caller_roles);

  EXECUTE format('REVOKE ALL ON %I.uony_creative_plan_heads,%I.creative_craft_input_legacy_cohorts,%I.creative_craft_input_legacy_exemptions,%I.creative_craft_input_plan_head_consumptions FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',s,s,s,s,caller_roles);
  EXECUTE format('GRANT SELECT,INSERT,UPDATE ON %I.uony_creative_plan_heads TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT SELECT,INSERT ON %I.creative_craft_input_plan_head_consumptions TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT SELECT,UPDATE ON %I.creative_craft_input_legacy_cohorts TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT SELECT ON %I.creative_craft_input_legacy_exemptions TO %I',s,binding.completion_definer_role);
  EXECUTE format('GRANT SELECT ON %I.creative_craft_input_legacy_cohorts,%I.creative_craft_input_legacy_exemptions TO %I',s,s,binding.receipt_definer_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_input_start_consumption_exact(uuid,uuid,timestamptz),%I.creative_craft_input_plan_head_bind(uuid,uuid,timestamptz) TO %I',s,s,binding.completion_definer_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_input_manifest_register(uuid,uuid,uuid,uuid,uuid,jsonb,text),%I.creative_craft_input_mint(uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb) TO %I',s,s,binding.input_verifier_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_input_legacy_exemption_status(uuid,uuid) TO %I',s,binding.input_verifier_role);

  FOREACH role_name IN ARRAY ARRAY[
      binding.preparer_role,binding.ack_role,binding.escrow_role,
      binding.launcher_verifier_role,binding.storage_verifier_role,
      binding.input_verifier_role] LOOP
    FOREACH relation_name IN ARRAY ARRAY[
      'uony_creative_plan_heads','creative_craft_input_legacy_cohorts',
      'creative_craft_input_legacy_exemptions',
      'creative_craft_input_plan_head_consumptions'] LOOP
      IF has_table_privilege(role_name,format('%I.%I',s,relation_name),
           'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         OR has_any_column_privilege(role_name,
           format('%I.%I',s,relation_name),
           'SELECT,INSERT,UPDATE,REFERENCES') THEN
        RAISE EXCEPTION 'Craft 120 caller gained direct table access after grants: % on %',
          role_name,relation_name USING ERRCODE='55000';
      END IF;
    END LOOP;
  END LOOP;
END $authority$;

DO $audit$
DECLARE binding record; cohort record;
BEGIN
  SELECT c.*,t.preparer_role,i.input_verifier_role INTO binding
    FROM creative_craft_input_legacy_cohorts sealed_cohort
    JOIN creative_craft_input_consumption_installation_bindings c
      ON c.installation_id=sealed_cohort.installation_id
    JOIN creative_craft_transition_installation_bindings t
      ON t.installation_key=c.installation_key
    JOIN creative_craft_input_installation_bindings i
      ON i.installation_key=c.installation_key;
  SELECT * INTO cohort FROM creative_craft_input_legacy_cohorts;
  IF cohort.desired_active
     OR cohort.selection_policy_sha256<>
          creative_craft_json_sha256(cohort.selection_policy)
     OR cohort.member_count<>(SELECT count(*)
          FROM creative_craft_input_legacy_exemptions exemption
         WHERE exemption.cohort_id=cohort.cohort_id)
     OR cohort.member_set_sha256<>creative_craft_json_sha256(coalesce((
          SELECT jsonb_agg(evidence ORDER BY user_id,attempt_id)
            FROM creative_craft_input_legacy_exemptions exemption
           WHERE exemption.cohort_id=cohort.cohort_id),'[]'::jsonb))
     OR cohort.redacted_member_count<0 OR cohort.redaction_epoch<0
     OR ((cohort.redaction_epoch=0)<>(cohort.last_redacted_at IS NULL)) THEN
    RAISE EXCEPTION 'Craft 120 sealed cohort audit failed'
      USING ERRCODE='55000';
  END IF;
  IF has_function_privilege('uonify_app_runtime',
       format('%I.creative_craft_input_legacy_exemption_status(uuid,uuid)',
              current_schema()),'EXECUTE')
     OR NOT has_function_privilege(binding.input_verifier_role,
       format('%I.creative_craft_input_legacy_exemption_status(uuid,uuid)',
              current_schema()),'EXECUTE') THEN
    RAISE EXCEPTION 'Craft 120 exemption status boundary is not closed'
      USING ERRCODE='55000';
  END IF;
END $audit$;
