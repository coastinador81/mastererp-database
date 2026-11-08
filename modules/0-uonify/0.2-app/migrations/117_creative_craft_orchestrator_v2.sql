-- Forward-only, inactive Craft materialization orchestrator ABI v2.
--
-- This gate adds a bounded population heartbeat and exact resume projections.
-- It deliberately does not connect a worker, provider, route, scheduler, or
-- candidate builder.  The installed Craft boundary remains fail-closed.

SELECT pg_advisory_xact_lock(
  hashtextextended('uonify-craft-materialization-v2',0));

DO $preflight$
DECLARE binding record; role_name text; relation_name text; database_oid oid;
BEGIN
  IF to_regclass('creative_craft_materialization_intents') IS NULL
     OR to_regclass('creative_craft_materialization_populations') IS NULL
     OR to_regprocedure(
       'creative_craft_materialization_claim_population(uuid,uuid,uuid)') IS NULL
     OR to_regprocedure(
       'creative_craft_materialization_claim_finalize(uuid,uuid,uuid,uuid,uuid)')
        IS NULL
     OR to_regprocedure(
       'creative_craft_materialization_renew_population(uuid,uuid,uuid,uuid,uuid)')
        IS NOT NULL THEN
    RAISE EXCEPTION 'Craft 117 requires one clean 116 installation'
      USING ERRCODE='55000';
  END IF;
  SELECT t.*,p.launcher_verifier_role,p.storage_verifier_role,
         p.receipt_definer_role,p.completion_definer_role INTO binding
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p
      USING(installation_key);
  IF binding.preparer_role IS NULL OR binding.desired_active THEN
    RAISE EXCEPTION 'Craft 117 requires one inactive installation binding'
      USING ERRCODE='55000';
  END IF;
  SELECT oid INTO database_oid FROM pg_database WHERE datname=current_database();
  FOREACH role_name IN ARRAY ARRAY[
      binding.preparer_role,binding.ack_role,binding.escrow_role,
      binding.definer_role,binding.launcher_verifier_role,
      binding.storage_verifier_role,binding.receipt_definer_role,
      binding.completion_definer_role] LOOP
    IF EXISTS(SELECT 1 FROM pg_roles r WHERE r.rolname=role_name AND
      (r.rolcanlogin OR r.rolinherit OR r.rolsuper OR r.rolcreatedb OR
       r.rolcreaterole OR r.rolreplication OR r.rolbypassrls OR
       EXISTS(SELECT 1 FROM pg_auth_members m
               WHERE m.roleid=r.oid OR m.member=r.oid) OR
       EXISTS(SELECT 1 FROM pg_shdepend dependency
        WHERE dependency.refclassid='pg_authid'::regclass
          AND dependency.refobjid=r.oid
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
                   AND relation.relname IN (
                     'users','creative_execution_jobs',
                     'creative_execution_steps','creative_execution_attempts',
                     'creative_craft_launcher_reservations',
                     'creative_runtime_reconciliation_outbox',
                     'creative_craft_launcher_ack_outbox',
                     'creative_craft_output_adoption_outbox',
                     'creative_candidate_receipts','creative_candidate_states',
                     'creative_candidate_quarantines',
                     'creative_candidate_quarantine_assets',
                     'creative_candidate_native_projects',
                     'creative_native_project_revisions',
                     'creative_craft_transition_installation_bindings',
                     'creative_craft_physical_installation_bindings',
                     'creative_craft_physical_challenges',
                     'creative_craft_physical_receipts',
                     'creative_craft_physical_receipt_consumptions',
                     'creative_craft_materialization_intents',
                     'creative_craft_materialization_populations'))
              ELSE true END)))) THEN
      RAISE EXCEPTION 'Craft 117 scoped role is not isolated: %',role_name
        USING ERRCODE='55000';
    END IF;
  END LOOP;
  FOREACH role_name IN ARRAY ARRAY[
      binding.preparer_role,binding.ack_role,binding.escrow_role,
      binding.launcher_verifier_role,binding.storage_verifier_role] LOOP
    FOREACH relation_name IN ARRAY ARRAY[
      'users','creative_execution_jobs','creative_execution_steps',
      'creative_execution_attempts','creative_craft_launcher_reservations',
      'creative_craft_materialization_intents',
      'creative_craft_materialization_populations',
      'creative_craft_physical_challenges',
      'creative_craft_physical_receipts',
      'creative_craft_physical_receipt_consumptions'] LOOP
      IF has_table_privilege(role_name,format('%I.%I',current_schema(),
           relation_name),'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
      THEN
        RAISE EXCEPTION 'Craft 117 caller gained direct DML: % on %',
          role_name,relation_name USING ERRCODE='55000';
      END IF;
    END LOOP;
  END LOOP;
END $preflight$;

CREATE OR REPLACE FUNCTION creative_craft_population_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (OLD.user_id,OLD.intent_id,OLD.attempt_id,OLD.population_generation_id,
      OLD.generation_no,OLD.population_namespace_id,OLD.installation_id,
      OLD.storage_domain_id,OLD.writer_token,OLD.population_fence_sha256,
      OLD.created_at) IS DISTINCT FROM
     (NEW.user_id,NEW.intent_id,NEW.attempt_id,NEW.population_generation_id,
      NEW.generation_no,NEW.population_namespace_id,NEW.installation_id,
      NEW.storage_domain_id,NEW.writer_token,NEW.population_fence_sha256,
      NEW.created_at) THEN
    RAISE EXCEPTION 'Craft population identity is immutable' USING ERRCODE='55000';
  END IF;
  IF OLD.plan IS NOT NULL AND
     (OLD.plan,OLD.plan_sha256,OLD.request_sha256,OLD.request_authority,
      OLD.profile_sha256,OLD.authority_sha256,OLD.bound_at) IS DISTINCT FROM
     (NEW.plan,NEW.plan_sha256,NEW.request_sha256,NEW.request_authority,
      NEW.profile_sha256,NEW.authority_sha256,NEW.bound_at) THEN
    RAISE EXCEPTION 'Craft population plan is immutable' USING ERRCODE='55000';
  END IF;
  IF NEW.finalize_attempt_count<OLD.finalize_attempt_count
     OR NEW.cleanup_attempt_count<OLD.cleanup_attempt_count THEN
    RAISE EXCEPTION 'Craft population attempts are monotonic' USING ERRCODE='55000';
  END IF;
  IF OLD.finalized_token IS DISTINCT FROM NEW.finalized_token
     AND NOT (OLD.finalized_token IS NULL
              AND OLD.state='finalizing' AND NEW.state='attached'
              AND NEW.finalized_token=OLD.finalize_token) THEN
    RAISE EXCEPTION 'Craft population finalized token is immutable'
      USING ERRCODE='55000';
  END IF;
  -- Gate 117 permits only the lease heartbeat to self-transition writing.
  IF OLD.state='writing' AND NEW.state='writing'
     AND (to_jsonb(OLD)-'writer_lease_until'-'updated_at')=
         (to_jsonb(NEW)-'writer_lease_until'-'updated_at') THEN
    RETURN NEW;
  END IF;
  IF NOT (
    (OLD.state='claimed_unbound' AND NEW.state IN ('writing','forgotten')) OR
    (OLD.state='writing' AND NEW.state IN ('receipt_ready','cleanup_required')) OR
    (OLD.state='receipt_ready' AND NEW.state IN ('finalizing','cleanup_required')) OR
    (OLD.state='finalizing' AND
       NEW.state IN ('finalizing','receipt_ready','attached','cleanup_required')) OR
    (OLD.state='cleanup_required' AND
       NEW.state IN ('cleanup_required','cleanup_running')) OR
    (OLD.state='cleanup_running' AND
       NEW.state IN ('cleanup_running','cleanup_required','cleanup_committed')) OR
    (OLD.state='cleanup_committed' AND
       NEW.state IN ('cleanup_committed','forgotten')) OR
    (OLD.state IN ('attached','legacy_attached') AND
       NEW.state='cleanup_required')) THEN
    RAISE EXCEPTION 'invalid Craft population transition' USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;

CREATE FUNCTION creative_craft_materialization_renew_population(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_generation_id uuid,
  p_writer_token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record; population record; install record;
        until_at timestamptz; request_body jsonb;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR owner_row.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
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
  SELECT installation_id,storage_domain_id INTO install
    FROM creative_craft_physical_installation_bindings;
  IF population.population_generation_id IS NULL
     OR population.state<>'writing'
     OR population.writer_token<>p_writer_token
     OR population.writer_lease_until<=clock_timestamp()
     OR clock_timestamp()>=population.created_at+interval '15 minutes'
     OR population.plan IS NULL OR population.plan_sha256 IS NULL
     OR population.request_sha256 IS NULL
     OR population.request_authority IS NULL
     OR creative_craft_json_sha256(population.plan)<>population.plan_sha256
     OR population.request_authority<>intent_row.request_authority
     OR (population.plan-'namespaceId'-'inputRoot'-'outputRoot')<>
          intent_row.logical_plan
     OR population.plan->>'namespaceId'<>
          population.population_namespace_id::text
     OR population.population_fence_sha256<>
          creative_craft_json_sha256(jsonb_build_object(
            'schemaVersion',1,'intentId',p_intent_id::text,
            'populationGenerationId',p_generation_id::text,
            'populationNamespaceId',population.population_namespace_id::text,
            'writerToken',p_writer_token::text,
            'storageDomainId',population.storage_domain_id::text,
            'intentFenceSha256',intent_row.plan_fence_sha256,
            'logicalPlanSha256',intent_row.logical_plan_sha256))
     OR population.installation_id<>install.installation_id
     OR population.storage_domain_id<>install.storage_domain_id
     OR intent_row.state<>'writing'
     OR job_row.status<>'running' OR step_row.status<>'running'
     OR attempt_row.status<>'running' OR step_row.kind<>'craft'
     OR NOT step_row.provider_call
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR attempt_row.claim_lease_token<>intent_row.claim_lease_token
     OR attempt_row.fence_epoch<>intent_row.fence_epoch
     OR job_row.lease_until<=clock_timestamp()
     OR step_row.lease_until<=clock_timestamp()
     OR attempt_row.lease_until<=clock_timestamp()
     OR job_row.lease_token<>attempt_row.lease_token
     OR step_row.lease_token<>attempt_row.lease_token
  THEN RETURN NULL; END IF;
  request_body:=jsonb_build_object('schemaVersion',2,
    'dispatchId',intent_row.dispatch_id::text,
    'attempt',jsonb_build_object('ownerUserId',p_user_id::text,
      'jobId',attempt_row.job_id::text,'stepId',attempt_row.step_id::text,
      'attemptId',attempt_row.id::text,'attemptNo',attempt_row.attempt_no,
      'claimLeaseToken',attempt_row.claim_lease_token::text,
      'fenceEpoch',attempt_row.fence_epoch,
      'admissionSha256',attempt_row.admission_sha256,
      'claimSetSha256',attempt_row.claim_set_sha256),
    'authority',population.request_authority);
  IF creative_craft_json_sha256(request_body)<>population.request_sha256 THEN
    RETURN NULL;
  END IF;
  until_at:=least(clock_timestamp()+interval '90 seconds',
                  population.created_at+interval '15 minutes');
  UPDATE creative_execution_jobs SET lease_until=until_at,
    updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND id=attempt_row.job_id;
  UPDATE creative_execution_steps SET lease_until=until_at,
    updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND job_id=attempt_row.job_id
     AND step_id=attempt_row.step_id;
  UPDATE creative_execution_attempts SET lease_until=until_at,
    updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND id=p_attempt_id;
  UPDATE creative_craft_materialization_populations
     SET writer_lease_until=until_at,updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND population_generation_id=p_generation_id;
  RETURN jsonb_build_object('status','writing',
    'populationGenerationId',population.population_generation_id::text,
    'populationNamespaceId',population.population_namespace_id::text,
    'populationLeaseToken',population.writer_token::text,
    'populationLeaseUntil',to_char(until_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'storageDomainId',population.storage_domain_id::text,
    'populationFenceSha256',population.population_fence_sha256,
    'planSha256',population.plan_sha256,
    'request',jsonb_build_object('body',request_body,
      'requestSha256',population.request_sha256));
END $$;

CREATE OR REPLACE FUNCTION creative_craft_materialization_claim_population(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record; active record; install record;
        stored record; proof_present boolean; attached_generation uuid;
        request_body jsonb;
        generation uuid:=gen_random_uuid(); namespace uuid:=gen_random_uuid();
        token uuid:=gen_random_uuid(); until_at timestamptz;
        generation_no integer; fence_hash text;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR owner_row.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
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
  IF intent_row.intent_id IS NULL THEN RETURN NULL; END IF;
  SELECT installation_id,storage_domain_id INTO install
    FROM creative_craft_physical_installation_bindings;
  IF install.installation_id IS NULL THEN RETURN NULL; END IF;
  IF intent_row.state='attached' THEN
    SELECT materialization_generation_id INTO attached_generation
      FROM creative_craft_launcher_reservations
     WHERE user_id=p_user_id AND attempt_id=p_attempt_id;
    IF attached_generation IS NULL THEN RETURN NULL; END IF;
    SELECT * INTO active FROM creative_craft_materialization_populations
     WHERE user_id=p_user_id AND intent_id=p_intent_id
       AND attempt_id=p_attempt_id
       AND population_generation_id=attached_generation FOR UPDATE;
    SELECT * INTO stored FROM creative_craft_launcher_reservations
     WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR SHARE;
    request_body:=jsonb_build_object('schemaVersion',2,
      'dispatchId',stored.dispatch_id::text,'attempt',jsonb_build_object(
        'ownerUserId',stored.user_id::text,'jobId',stored.job_id::text,
        'stepId',stored.step_id::text,'attemptId',stored.attempt_id::text,
        'attemptNo',stored.attempt_no,
        'claimLeaseToken',stored.claim_lease_token::text,
        'fenceEpoch',stored.fence_epoch,
        'admissionSha256',stored.admission_sha256,
        'claimSetSha256',stored.claim_set_sha256),
      'authority',stored.request_authority);
    SELECT EXISTS(SELECT 1
      FROM creative_craft_physical_receipt_consumptions consumption
     WHERE consumption.user_id=p_user_id
       AND consumption.receipt_id=active.receipt_id
       AND consumption.attempt_id=p_attempt_id
       AND consumption.completion_kind='materialization'
       AND consumption.materialization_generation_id=attached_generation)
      INTO proof_present;
    IF active.state<>'attached' OR active.receipt_id IS NULL
       OR active.finalized_token IS NULL OR NOT proof_present
       OR active.installation_id<>install.installation_id
       OR active.storage_domain_id<>install.storage_domain_id
       OR creative_craft_json_sha256(active.plan)<>active.plan_sha256
       OR stored.materialization_intent_id<>p_intent_id
       OR stored.materialization_generation_id<>attached_generation
       OR stored.storage_domain_id<>active.storage_domain_id
       OR stored.request_sha256<>active.request_sha256
       OR stored.authority_sha256<>active.authority_sha256
       OR stored.profile_sha256<>active.profile_sha256
       OR stored.dispatch_id<>intent_row.dispatch_id
       OR creative_craft_json_sha256(request_body)<>stored.request_sha256
    THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('status','attached',
      'intentId',p_intent_id::text,
      'populationGenerationId',attached_generation::text,
      'storageDomainId',active.storage_domain_id::text,
      'request',jsonb_build_object('body',request_body,
        'requestSha256',stored.request_sha256),
      'authoritySha256',stored.authority_sha256,
      'profileSha256',stored.profile_sha256);
  END IF;
  IF intent_row.state<>'writing' OR job_row.status<>'running'
     OR step_row.status<>'running' OR attempt_row.status<>'running'
     OR step_row.kind<>'craft' OR NOT step_row.provider_call
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR attempt_row.claim_lease_token<>intent_row.claim_lease_token
     OR attempt_row.fence_epoch<>intent_row.fence_epoch
     OR job_row.lease_until<=clock_timestamp()
     OR step_row.lease_until<=clock_timestamp()
     OR attempt_row.lease_until<=clock_timestamp()
     OR job_row.lease_token<>attempt_row.lease_token
     OR step_row.lease_token<>attempt_row.lease_token
  THEN RETURN NULL; END IF;
  SELECT * INTO active FROM creative_craft_materialization_populations
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND state IN ('claimed_unbound','writing','receipt_ready','finalizing')
   FOR UPDATE;
  IF FOUND AND (active.installation_id<>install.installation_id
                OR active.storage_domain_id<>install.storage_domain_id) THEN
    RETURN NULL;
  END IF;
  IF FOUND AND active.state='receipt_ready' THEN
    RETURN jsonb_build_object('status','receipt_ready',
      'populationGenerationId',active.population_generation_id::text,
      'receiptId',active.receipt_id::text,
      'storageDomainId',active.storage_domain_id::text,
      'populationFenceSha256',active.population_fence_sha256,
      'planSha256',active.plan_sha256);
  END IF;
  IF FOUND AND active.state='finalizing' THEN
    RETURN jsonb_build_object('status','finalizing',
      'populationGenerationId',active.population_generation_id::text,
      'receiptId',active.receipt_id::text,
      'storageDomainId',active.storage_domain_id::text,
      'populationFenceSha256',active.population_fence_sha256,
      'planSha256',active.plan_sha256,
      'finalizeLeaseUntil',to_char(active.finalize_lease_until AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
  END IF;
  IF FOUND AND active.writer_lease_until>clock_timestamp() THEN
    RETURN jsonb_build_object('status','busy',
      'populationState',active.state,
      'populationGenerationId',active.population_generation_id::text,
      'storageDomainId',active.storage_domain_id::text,
      'populationLeaseUntil',to_char(active.writer_lease_until AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
  END IF;
  IF FOUND THEN
    IF active.state='claimed_unbound' THEN
      UPDATE creative_craft_materialization_populations SET state='forgotten',
        writer_lease_until=NULL,forgotten_at=clock_timestamp(),
        updated_at=clock_timestamp()
       WHERE user_id=p_user_id
         AND population_generation_id=active.population_generation_id;
    ELSE
      UPDATE creative_craft_materialization_populations
         SET state='cleanup_required',writer_lease_until=NULL,
             available_at=clock_timestamp(),updated_at=clock_timestamp()
       WHERE user_id=p_user_id
         AND population_generation_id=active.population_generation_id;
    END IF;
  END IF;
  SELECT coalesce(max(p.generation_no),0)+1 INTO generation_no
    FROM creative_craft_materialization_populations p
   WHERE p.user_id=p_user_id AND p.intent_id=p_intent_id;
  until_at:=clock_timestamp()+interval '5 minutes';
  fence_hash:=creative_craft_json_sha256(jsonb_build_object(
    'schemaVersion',1,'intentId',p_intent_id::text,
    'populationGenerationId',generation::text,
    'populationNamespaceId',namespace::text,'writerToken',token::text,
    'storageDomainId',install.storage_domain_id::text,
    'intentFenceSha256',intent_row.plan_fence_sha256,
    'logicalPlanSha256',intent_row.logical_plan_sha256));
  INSERT INTO creative_craft_materialization_populations(
    user_id,intent_id,attempt_id,population_generation_id,generation_no,
    population_namespace_id,installation_id,storage_domain_id,state,
    writer_token,writer_lease_until,population_fence_sha256)
  VALUES(p_user_id,p_intent_id,p_attempt_id,generation,generation_no,namespace,
    install.installation_id,install.storage_domain_id,'claimed_unbound',token,
    until_at,fence_hash);
  RETURN jsonb_build_object('status','claimed_unbound',
    'populationGenerationId',generation::text,
    'populationNamespaceId',namespace::text,
    'populationLeaseToken',token::text,
    'populationLeaseUntil',to_char(until_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'storageDomainId',install.storage_domain_id::text,
    'populationFenceSha256',fence_hash,
    'logicalPlan',intent_row.logical_plan,
    'logicalPlanSha256',intent_row.logical_plan_sha256);
END $$;

CREATE OR REPLACE FUNCTION creative_craft_materialization_claim_finalize(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_generation_id uuid,
  p_receipt_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record;
        population record; install record; token uuid:=gen_random_uuid();
        until_at timestamptz;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR owner_row.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
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
  SELECT installation_id,storage_domain_id INTO install
    FROM creative_craft_physical_installation_bindings;
  IF population.population_generation_id IS NULL
     OR intent_row.intent_id IS NULL OR intent_row.state<>'writing'
     OR install.installation_id IS NULL
     OR population.receipt_id<>p_receipt_id
     OR population.installation_id<>install.installation_id
     OR population.storage_domain_id<>install.storage_domain_id
     OR job_row.status<>'running' OR step_row.status<>'running'
     OR attempt_row.status<>'running' OR step_row.kind<>'craft'
     OR NOT step_row.provider_call
     OR job_row.lease_until<=clock_timestamp()
     OR step_row.lease_until<=clock_timestamp()
     OR attempt_row.lease_until<=clock_timestamp()
     OR job_row.lease_token<>attempt_row.lease_token
     OR step_row.lease_token<>attempt_row.lease_token
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR attempt_row.claim_lease_token<>intent_row.claim_lease_token
     OR attempt_row.fence_epoch<>intent_row.fence_epoch
  THEN RETURN NULL; END IF;
  IF population.state='finalizing'
     AND population.finalize_lease_until>clock_timestamp() THEN
    RETURN jsonb_build_object('status','busy',
      'populationGenerationId',p_generation_id::text,
      'receiptId',p_receipt_id::text,
      'storageDomainId',population.storage_domain_id::text,
      'finalizeLeaseUntil',to_char(population.finalize_lease_until
        AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
  END IF;
  IF population.state NOT IN ('receipt_ready','finalizing') THEN RETURN NULL; END IF;
  until_at:=clock_timestamp()+interval '2 minutes';
  UPDATE creative_craft_materialization_populations SET state='finalizing',
    finalize_token=token,finalize_lease_until=until_at,
    finalize_attempt_count=finalize_attempt_count+1,updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND population_generation_id=p_generation_id;
  RETURN jsonb_build_object('status','finalizing',
    'populationGenerationId',p_generation_id::text,
    'receiptId',p_receipt_id::text,'finalizeToken',token::text,
    'finalizeLeaseUntil',to_char(until_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'storageDomainId',population.storage_domain_id::text);
END $$;

DO $authority$
DECLARE s text:=current_schema(); binding record; f record; caller_roles text;
BEGIN
  SELECT t.*,p.launcher_verifier_role,p.storage_verifier_role,
         p.receipt_definer_role,p.completion_definer_role INTO binding
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p USING(installation_key);
  caller_roles:=concat_ws(',',binding.preparer_role,binding.ack_role,
    binding.escrow_role,binding.launcher_verifier_role,
    binding.storage_verifier_role);
  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
    'creative_craft_population_guard',
    'creative_craft_materialization_claim_population',
    'creative_craft_materialization_renew_population',
    'creative_craft_materialization_claim_finalize') LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.signature,
                   binding.completion_definer_role);
    EXECUTE format('ALTER FUNCTION %s SET search_path TO pg_catalog,%I,pg_temp',
                   f.signature,s);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',
                   f.signature,caller_roles);
  END LOOP;
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_materialization_claim_population(uuid,uuid,uuid),%I.creative_craft_materialization_renew_population(uuid,uuid,uuid,uuid,uuid),%I.creative_craft_materialization_claim_finalize(uuid,uuid,uuid,uuid,uuid) TO %I',
                 s,s,s,binding.preparer_role);
END $authority$;

DO $audit$
DECLARE s text:=current_schema(); binding record; role_name text;
        signature text:=format(
          '%I.creative_craft_materialization_renew_population(uuid,uuid,uuid,uuid,uuid)',
          current_schema());
BEGIN
  SELECT t.*,p.launcher_verifier_role,p.storage_verifier_role,
         p.receipt_definer_role,p.completion_definer_role INTO binding
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p USING(installation_key);
  IF binding.desired_active
     OR NOT has_function_privilege(binding.preparer_role,signature,'EXECUTE')
     OR has_function_privilege('uonify_app_runtime',signature,'EXECUTE') THEN
    RAISE EXCEPTION 'Craft 117 activation boundary is not closed'
      USING ERRCODE='55000';
  END IF;
  FOREACH role_name IN ARRAY ARRAY[
      binding.ack_role,binding.escrow_role,binding.launcher_verifier_role,
      binding.storage_verifier_role] LOOP
    IF has_function_privilege(role_name,signature,'EXECUTE') THEN
      RAISE EXCEPTION 'Craft 117 renewal leaked to role %',role_name
        USING ERRCODE='55000';
    END IF;
  END LOOP;
  IF EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname=s AND p.proname IN (
       'creative_craft_materialization_claim_population',
       'creative_craft_materialization_renew_population',
       'creative_craft_materialization_claim_finalize')
       AND (NOT p.prosecdef OR pg_get_userbyid(p.proowner)<>
            binding.completion_definer_role)) THEN
    RAISE EXCEPTION 'Craft 117 function ownership is not scoped'
      USING ERRCODE='55000';
  END IF;
END $audit$;
