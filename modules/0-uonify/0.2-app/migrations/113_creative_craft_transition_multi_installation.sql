-- Forward-only inactive hardening for the Craft transition API.
-- This migration scopes roles to one database/schema installation, records a
-- server-owned inactive binding, and replaces the broad escrow dequeue with a
-- read-only shortlist plus an exact user/escrow claim.  It does not activate a
-- worker, attest external I/O, or make this SQL API the sole transition path.
-- A baseline already committed at 112 can still require an external migrator
-- lock or rebaseline before another schema reaches 113, because 110 fails
-- closed on the fixed ACLs intentionally installed by 112.
-- Account deletion does not yet take the account advisory lock.  The users row
-- lock is the database backstop for claim-vs-deletion ordering; moving deletion
-- itself behind the same advisory protocol remains a 114 integration blocker.

SELECT pg_advisory_xact_lock(
    hashtextextended('uonify-craft-launcher-roles-v1',0));
SELECT pg_advisory_xact_lock(
    hashtextextended('uonify-craft-transition-api-v1',0));
SELECT pg_advisory_xact_lock(
    hashtextextended('uonify-craft-transition-api-v2',0));

CREATE TABLE creative_craft_transition_installation_bindings (
    installation_key text PRIMARY KEY CHECK (installation_key ~ '^[0-9a-f]{24}$'),
    database_name text NOT NULL,
    schema_name text NOT NULL,
    preparer_role text NOT NULL UNIQUE,
    ack_role text NOT NULL UNIQUE,
    escrow_role text NOT NULL UNIQUE,
    definer_role text NOT NULL UNIQUE,
    desired_active boolean NOT NULL DEFAULT false CHECK (NOT desired_active),
    authority_mode text NOT NULL DEFAULT 'inactive_parallel'
      CHECK (authority_mode='inactive_parallel'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (database_name,schema_name)
);

CREATE FUNCTION creative_craft_transition_binding_append_only()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION 'Craft transition installation binding is append-only'
    USING ERRCODE='55000';
END $$;
CREATE TRIGGER creative_craft_transition_binding_append_only
BEFORE UPDATE OR DELETE ON creative_craft_transition_installation_bindings
FOR EACH ROW EXECUTE FUNCTION creative_craft_transition_binding_append_only();
REVOKE ALL ON creative_craft_transition_installation_bindings FROM PUBLIC;
REVOKE ALL ON FUNCTION creative_craft_transition_binding_append_only() FROM PUBLIC;

DO $roles$
DECLARE s text:=current_schema();
        k text:=substr(md5(length(current_database())::text||':'||current_database()||':'||
          length(current_schema())::text||':'||current_schema()),1,24);
        role_name text; dirty text;
        roles text[]:=ARRAY['uonify_craft_prep_'||k,'uonify_craft_ack_'||k,
          'uonify_craft_esc_'||k,'uonify_craft_def_'||k];
BEGIN
  FOREACH role_name IN ARRAY roles LOOP
    dirty:=NULL;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname=role_name) THEN
      SELECT CASE
        WHEN r.rolcanlogin OR r.rolinherit OR r.rolsuper OR r.rolcreatedb OR
             r.rolcreaterole OR r.rolreplication OR r.rolbypassrls THEN 'capability'
        WHEN EXISTS (SELECT 1 FROM pg_auth_members m
                     WHERE m.roleid=r.oid OR m.member=r.oid) THEN 'membership'
        WHEN EXISTS (SELECT 1 FROM pg_shdepend d
                     WHERE d.refclassid='pg_authid'::regclass
                       AND d.refobjid=r.oid AND d.deptype IN ('a','o')) THEN 'dependency'
        END INTO dirty FROM pg_roles r WHERE r.rolname=role_name;
      IF dirty IS NOT NULL THEN
        RAISE EXCEPTION 'pre-existing scoped Craft role is contaminated: % (%)',
          role_name,dirty USING ERRCODE='55000';
      END IF;
    ELSE
      EXECUTE format('CREATE ROLE %I NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',role_name);
    END IF;
    EXECUTE format('ALTER ROLE %I NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',role_name);
  END LOOP;
  INSERT INTO creative_craft_transition_installation_bindings(
    installation_key,database_name,schema_name,preparer_role,ack_role,
    escrow_role,definer_role)
  VALUES(k,current_database(),s,roles[1],roles[2],roles[3],roles[4]);
END $roles$;

DO $migration$
DECLARE s text := current_schema();
        install_key text := substr(md5(length(current_database())::text||':'||
          current_database()||':'||length(current_schema())::text||':'||current_schema()),1,24);
        prep_role text; ack_role text; esc_role text;
BEGIN
prep_role := 'uonify_craft_prep_'||install_key;
ack_role := 'uonify_craft_ack_'||install_key;
esc_role := 'uonify_craft_esc_'||install_key;
EXECUTE replace(replace(replace(replace($ddl$
CREATE OR REPLACE FUNCTION __SCHEMA__.creative_craft_preparer_claim_compensation(
    p_user_id uuid,p_attempt_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record; seed record; j record; st record; a record; r record;
        token uuid:=gen_random_uuid();
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM '__PREP_ROLE__' THEN
        RAISE EXCEPTION 'Craft preparer role required' USING ERRCODE='42501';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
      'uonify:account:'||p_user_id::text,0));
    SELECT deletion_requested_at INTO u FROM __SCHEMA__.users
     WHERE id=p_user_id FOR NO KEY UPDATE;
    -- Compensation closes a provider reservation that already exists.  It is
    -- cleanup, so account deletion must not strand this blocker.
    IF NOT FOUND THEN RETURN NULL; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
      'uonify:craft-attempt:'||p_attempt_id::text,0));
    SELECT job_id,step_id INTO seed FROM __SCHEMA__.creative_execution_attempts
     WHERE user_id=p_user_id AND id=p_attempt_id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT status,lease_token,lease_until INTO j FROM __SCHEMA__.creative_execution_jobs
     WHERE user_id=p_user_id AND id=seed.job_id FOR UPDATE;
    SELECT status,kind,provider_call,lease_token,lease_until,
           provider_started_at,provider_returned_at INTO st
      FROM __SCHEMA__.creative_execution_steps
     WHERE user_id=p_user_id AND job_id=seed.job_id AND step_id=seed.step_id FOR UPDATE;
    SELECT status,job_id,step_id,attempt_no,lease_token,lease_until,
           claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,
           provider_started_at,provider_returned_at INTO a
      FROM __SCHEMA__.creative_execution_attempts
     WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
    IF NOT FOUND OR st.kind<>'craft' OR NOT st.provider_call
       OR st.provider_started_at IS NOT NULL OR st.provider_returned_at IS NOT NULL
       OR a.provider_started_at IS NOT NULL OR a.provider_returned_at IS NOT NULL
       OR a.job_id<>seed.job_id OR a.step_id<>seed.step_id
       THEN RETURN NULL; END IF;
    SELECT user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,
           fence_epoch,admission_sha256,claim_set_sha256,dispatch_id,
           request_sha256,input_root,output_root,reserved_at,
           compensation_status,compensation_lease_token,
           compensation_lease_until,compensation_attempt_count INTO r FROM __SCHEMA__.creative_craft_launcher_reservations
     WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
    IF NOT FOUND OR r.job_id<>a.job_id OR r.step_id<>a.step_id
       OR r.attempt_no<>a.attempt_no OR r.claim_lease_token<>a.claim_lease_token
       OR r.fence_epoch<>a.fence_epoch OR r.admission_sha256<>a.admission_sha256
       OR r.claim_set_sha256<>a.claim_set_sha256 OR r.reserved_at IS NOT NULL
       THEN RETURN NULL; END IF;
    UPDATE __SCHEMA__.creative_craft_launcher_reservations
       SET compensation_status='running',compensation_lease_token=token,
           compensation_lease_until=clock_timestamp()+interval '2 minutes',
           compensation_attempt_count=compensation_attempt_count+1,
           compensation_last_error=NULL,updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND attempt_id=p_attempt_id
       AND (compensation_status='pending' OR
           (compensation_status='running' AND compensation_lease_until<=clock_timestamp()))
     RETURNING user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,
           fence_epoch,admission_sha256,claim_set_sha256,dispatch_id,
           request_sha256,input_root,output_root,reserved_at,
           compensation_status,compensation_lease_token,
           compensation_lease_until,compensation_attempt_count INTO r;
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('leaseToken',token,'attemptCount',r.compensation_attempt_count,
      'dispatchId',r.dispatch_id,'requestSha256',r.request_sha256,
      'inputRoot',r.input_root,'outputRoot',r.output_root);
END $body$;
$ddl$,'__SCHEMA__',quote_ident(s)),'__PREP_ROLE__',prep_role),'__ACK_ROLE__',ack_role),'__ESC_ROLE__',esc_role);

EXECUTE replace(replace(replace(replace($ddl$
CREATE OR REPLACE FUNCTION __SCHEMA__.creative_craft_preparer_release_compensation(
    p_user_id uuid,p_attempt_id uuid,p_lease_token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record;
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM '__PREP_ROLE__' THEN
        RAISE EXCEPTION 'Craft preparer role required' USING ERRCODE='42501';
    END IF;
    SELECT deletion_requested_at INTO u FROM __SCHEMA__.users
      WHERE id=p_user_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;
    UPDATE __SCHEMA__.creative_craft_launcher_reservations
       SET compensation_lease_until=clock_timestamp(),
           compensation_last_error='transition_failed',updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND attempt_id=p_attempt_id
       AND compensation_status='running' AND compensation_lease_token=p_lease_token;
    RETURN FOUND;
END $body$;
$ddl$,'__SCHEMA__',quote_ident(s)),'__PREP_ROLE__',prep_role),'__ACK_ROLE__',ack_role),'__ESC_ROLE__',esc_role);

EXECUTE replace(replace(replace(replace($ddl$
CREATE OR REPLACE FUNCTION __SCHEMA__.creative_craft_ack_claim(
    p_user_id uuid,p_attempt_id uuid,p_runtime_lease_token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record; a record; r record; runtime record; ack record;
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM '__ACK_ROLE__' THEN
        RAISE EXCEPTION 'Craft ACK role required' USING ERRCODE='42501';
    END IF;
    SELECT deletion_requested_at INTO u FROM __SCHEMA__.users
      WHERE id=p_user_id FOR NO KEY UPDATE;
    IF NOT FOUND OR u.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
    SELECT status,job_id,step_id,attempt_no,claim_lease_token,fence_epoch,
           admission_sha256,claim_set_sha256 INTO a
      FROM __SCHEMA__.creative_execution_attempts
     WHERE user_id=p_user_id AND id=p_attempt_id;
    IF NOT FOUND OR a.status NOT IN ('succeeded','failed','cancelled') THEN RETURN NULL; END IF;
    SELECT dispatch_id,request_sha256,authority_sha256,compensation_status INTO r
      FROM __SCHEMA__.creative_craft_launcher_reservations
     WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR SHARE;
    IF NOT FOUND OR r.compensation_status<>'confirmed' THEN RETURN NULL; END IF;
    SELECT user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,
           fence_epoch,admission_sha256,claim_set_sha256,terminal_status,
           status,lease_token,lease_until INTO runtime FROM __SCHEMA__.creative_runtime_reconciliation_outbox
     WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
    IF NOT FOUND OR runtime.status<>'running' OR runtime.lease_token<>p_runtime_lease_token
       OR runtime.lease_until<=clock_timestamp() OR runtime.terminal_status<>a.status
       OR (runtime.job_id,runtime.step_id,runtime.attempt_no,runtime.claim_lease_token,
           runtime.fence_epoch,runtime.admission_sha256,runtime.claim_set_sha256)
          IS DISTINCT FROM (a.job_id,a.step_id,a.attempt_no,a.claim_lease_token,
           a.fence_epoch,a.admission_sha256,a.claim_set_sha256) THEN RETURN NULL; END IF;
    SELECT user_id,source_attempt_id,job_id,source_step_id,attempt_no,
           claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,
           terminal_status,dispatch_id,request_sha256,authority_sha256,
           terminal_receipt_sha256,candidate_id,quarantine_set_sha256,
           adoption_attempt_id,adoption_fence_epoch,adoption_result_sha256,
           status,lease_token,lease_until,attempt_count,completed_at INTO ack FROM __SCHEMA__.creative_craft_launcher_ack_outbox
     WHERE user_id=p_user_id AND source_attempt_id=p_attempt_id FOR UPDATE;
    IF NOT FOUND OR ack.terminal_status<>a.status OR ack.dispatch_id<>r.dispatch_id
       OR ack.request_sha256<>r.request_sha256 OR ack.authority_sha256<>r.authority_sha256
       THEN RETURN NULL; END IF;
    IF ack.status='done' THEN
      RETURN jsonb_build_object('applied',false,'status','done','dispatchId',r.dispatch_id);
    END IF;
    UPDATE __SCHEMA__.creative_craft_launcher_ack_outbox
       SET status='running',lease_token=p_runtime_lease_token,
           lease_until=runtime.lease_until,attempt_count=attempt_count+1,
           last_error=NULL,updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND source_attempt_id=p_attempt_id
       AND (status='pending' OR (status='running' AND
            (lease_token=p_runtime_lease_token OR lease_until<=clock_timestamp())))
     RETURNING status,lease_token,lease_until,attempt_count INTO ack;
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('applied',true,'status','running',
      'dispatchId',r.dispatch_id,'requestSha256',r.request_sha256,
      'runtimeLeaseToken',p_runtime_lease_token);
END $body$;
$ddl$,'__SCHEMA__',quote_ident(s)),'__PREP_ROLE__',prep_role),'__ACK_ROLE__',ack_role),'__ESC_ROLE__',esc_role);

EXECUTE replace(replace(replace(replace($ddl$
CREATE OR REPLACE FUNCTION __SCHEMA__.creative_craft_ack_release(
    p_user_id uuid,p_attempt_id uuid,p_runtime_lease_token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record; runtime record;
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM '__ACK_ROLE__' THEN
        RAISE EXCEPTION 'Craft ACK role required' USING ERRCODE='42501';
    END IF;
    SELECT deletion_requested_at INTO u FROM __SCHEMA__.users
      WHERE id=p_user_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;
    SELECT status,lease_token INTO runtime
      FROM __SCHEMA__.creative_runtime_reconciliation_outbox
     WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
    IF NOT FOUND OR runtime.status<>'running' OR runtime.lease_token<>p_runtime_lease_token
       THEN RETURN false; END IF;
    UPDATE __SCHEMA__.creative_craft_launcher_ack_outbox
       SET status='pending',lease_token=NULL,lease_until=NULL,
           last_error='transition_failed',updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND source_attempt_id=p_attempt_id
       AND status='running' AND lease_token=p_runtime_lease_token;
    RETURN FOUND;
END $body$;
$ddl$,'__SCHEMA__',quote_ident(s)),'__PREP_ROLE__',prep_role),'__ACK_ROLE__',ack_role),'__ESC_ROLE__',esc_role);

EXECUTE replace(replace(replace(replace($ddl$
CREATE OR REPLACE FUNCTION __SCHEMA__.creative_craft_escrow_shortlist(
    p_user_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record; result jsonb;
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM '__ESC_ROLE__' THEN
        RAISE EXCEPTION 'Craft escrow role required' USING ERRCODE='42501';
    END IF;
    SELECT deletion_requested_at INTO u FROM __SCHEMA__.users
     WHERE id=p_user_id;
    IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'userId',q.user_id,'escrowId',q.escrow_id,'version',q.version,
      'state',q.state) ORDER BY q.created_at,q.escrow_id),'[]'::jsonb)
      INTO result
      FROM (SELECT user_id,escrow_id,version,state,created_at
              FROM __SCHEMA__.creative_craft_output_adoption_outbox
             WHERE user_id=p_user_id AND available_at<=clock_timestamp()
               AND (u.deletion_requested_at IS NULL OR
                    state IN ('reconciliation_pending','reconciling_cleanup'))
               AND (state IN ('pending_adoption','reconciliation_pending') OR
                   (state IN ('adopting','reconciling_cleanup') AND
                    lease_until<=clock_timestamp()))
             ORDER BY created_at,escrow_id LIMIT 32) q;
    RETURN result;
END $body$;
$ddl$,'__SCHEMA__',quote_ident(s)),'__PREP_ROLE__',prep_role),'__ACK_ROLE__',ack_role),'__ESC_ROLE__',esc_role);

EXECUTE replace(replace(replace(replace($ddl$
CREATE OR REPLACE FUNCTION __SCHEMA__.creative_craft_escrow_claim(
    p_user_id uuid,p_escrow_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE peek record; row record; u record; j record; st record; a record;
        r record; runtime record; token uuid:=gen_random_uuid();
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM '__ESC_ROLE__' THEN
        RAISE EXCEPTION 'Craft escrow role required' USING ERRCODE='42501';
    END IF;
    IF NOT pg_try_advisory_xact_lock(hashtextextended(
      'uonify:account:'||p_user_id::text,0)) THEN
      RETURN NULL;
    END IF;
    SELECT deletion_requested_at INTO u FROM __SCHEMA__.users
     WHERE id=p_user_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT user_id,escrow_id,source_attempt_id,candidate_id,job_id,source_step_id,
           attempt_no,claim_lease_token,fence_epoch,admission_sha256,
           claim_set_sha256,terminal_status,dispatch_id,request_sha256,
           authority_sha256,escrow_manifest_sha256,escrow_manifest,state,
           version,lease_token,lease_until,attempt_count,available_at,created_at,
           quarantine_set_sha256,adoption_attempt_id,adoption_fence_epoch,
           adoption_result_sha256 INTO peek
      FROM __SCHEMA__.creative_craft_output_adoption_outbox
     WHERE user_id=p_user_id AND escrow_id=p_escrow_id;
    IF NOT FOUND OR (u.deletion_requested_at IS NOT NULL AND
       peek.state IN ('pending_adoption','adopting')) THEN RETURN NULL; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
      'uonify:craft-attempt:'||peek.source_attempt_id::text,0));
    SELECT status INTO j FROM __SCHEMA__.creative_execution_jobs
     WHERE user_id=p_user_id AND id=peek.job_id FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT status,kind,provider_call INTO st FROM __SCHEMA__.creative_execution_steps
     WHERE user_id=p_user_id AND job_id=peek.job_id
       AND step_id=peek.source_step_id FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT status,job_id,step_id,attempt_no,claim_lease_token,fence_epoch,
           admission_sha256,claim_set_sha256 INTO a
      FROM __SCHEMA__.creative_execution_attempts
     WHERE user_id=p_user_id AND id=peek.source_attempt_id FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT compensation_status,job_id,step_id,attempt_no,claim_lease_token,
           fence_epoch,admission_sha256,claim_set_sha256,dispatch_id,
           request_sha256,authority_sha256 INTO r
      FROM __SCHEMA__.creative_craft_launcher_reservations
     WHERE user_id=p_user_id AND attempt_id=peek.source_attempt_id FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT terminal_status INTO runtime
      FROM __SCHEMA__.creative_runtime_reconciliation_outbox
     WHERE user_id=p_user_id AND attempt_id=peek.source_attempt_id FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT user_id,escrow_id,source_attempt_id,candidate_id,job_id,source_step_id,
           attempt_no,claim_lease_token,fence_epoch,admission_sha256,
           claim_set_sha256,terminal_status,dispatch_id,request_sha256,
           authority_sha256,escrow_manifest_sha256,escrow_manifest,state,
           version,lease_token,lease_until,attempt_count,available_at,created_at,
           quarantine_set_sha256,adoption_attempt_id,adoption_fence_epoch,
           adoption_result_sha256 INTO row
      FROM __SCHEMA__.creative_craft_output_adoption_outbox
     WHERE user_id=p_user_id AND escrow_id=p_escrow_id
     FOR UPDATE SKIP LOCKED;
    IF NOT FOUND OR row.version<>peek.version
       OR row.available_at>clock_timestamp()
       OR NOT (row.state IN ('pending_adoption','reconciliation_pending') OR
          (row.state IN ('adopting','reconciling_cleanup') AND
           row.lease_until<=clock_timestamp()))
       OR a.status<>'succeeded' OR st.kind<>'craft' OR NOT st.provider_call
       OR r.compensation_status<>'confirmed' OR runtime.terminal_status<>'succeeded'
       OR (a.job_id,a.step_id,a.attempt_no,a.claim_lease_token,a.fence_epoch,
           a.admission_sha256,a.claim_set_sha256) IS DISTINCT FROM
          (row.job_id,row.source_step_id,row.attempt_no,row.claim_lease_token,
           row.fence_epoch,row.admission_sha256,row.claim_set_sha256)
       OR (r.job_id,r.step_id,r.attempt_no,r.claim_lease_token,r.fence_epoch,
           r.admission_sha256,r.claim_set_sha256,r.dispatch_id,r.request_sha256,
           r.authority_sha256) IS DISTINCT FROM
          (row.job_id,row.source_step_id,row.attempt_no,row.claim_lease_token,
           row.fence_epoch,row.admission_sha256,row.claim_set_sha256,
           row.dispatch_id,row.request_sha256,row.authority_sha256)
       THEN RETURN NULL; END IF;
    UPDATE __SCHEMA__.creative_craft_output_adoption_outbox
       SET state=CASE WHEN row.state IN ('pending_adoption','adopting')
                      THEN 'adopting' ELSE 'reconciling_cleanup' END,
           version=version+1,lease_token=token,
           lease_until=clock_timestamp()+interval '2 minutes',
           attempt_count=attempt_count+1,last_error=NULL,updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND escrow_id=p_escrow_id AND version=row.version
       AND available_at<=clock_timestamp()
       AND (state IN ('pending_adoption','reconciliation_pending') OR
           (state IN ('adopting','reconciling_cleanup') AND
            lease_until<=clock_timestamp()))
     RETURNING user_id,escrow_id,source_attempt_id,candidate_id,state,version,
               lease_token,attempt_count,escrow_manifest INTO row;
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('userId',row.user_id,'escrowId',row.escrow_id,
      'sourceAttemptId',row.source_attempt_id,'candidateId',row.candidate_id,
      'state',row.state,'version',row.version,'leaseToken',token,
      'escrowManifest',row.escrow_manifest);
END $body$;
$ddl$,'__SCHEMA__',quote_ident(s)),'__PREP_ROLE__',prep_role),'__ACK_ROLE__',ack_role),'__ESC_ROLE__',esc_role);

EXECUTE replace(replace(replace(replace($ddl$
CREATE OR REPLACE FUNCTION __SCHEMA__.creative_craft_escrow_schedule_cleanup(
    p_user_id uuid,p_escrow_id uuid,p_version integer) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record; o record; locked record; ack record; q record; cs record;
        ack_exact boolean:=false;
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM '__ESC_ROLE__' THEN
        RAISE EXCEPTION 'Craft escrow role required' USING ERRCODE='42501';
    END IF;
    SELECT user_id,escrow_id,source_attempt_id,candidate_id,job_id,source_step_id,
           attempt_no,claim_lease_token,fence_epoch,admission_sha256,
           claim_set_sha256,terminal_status,dispatch_id,request_sha256,
           authority_sha256,escrow_manifest_sha256,escrow_manifest,state,
           version,lease_token,lease_until,attempt_count,available_at,created_at,
           quarantine_set_sha256,adoption_attempt_id,adoption_fence_epoch,
           adoption_result_sha256 INTO o FROM __SCHEMA__.creative_craft_output_adoption_outbox
     WHERE user_id=p_user_id AND escrow_id=p_escrow_id;
    IF NOT FOUND THEN RETURN false; END IF;
    SELECT deletion_requested_at INTO u FROM __SCHEMA__.users
      WHERE id=p_user_id FOR NO KEY UPDATE;
    -- Moving durable adoption into reconciliation drains an existing blocker
    -- and remains permitted while account deletion is pending.
    IF NOT FOUND THEN RETURN false; END IF;
    PERFORM 1 FROM __SCHEMA__.creative_execution_jobs
     WHERE user_id=p_user_id AND id=o.job_id FOR UPDATE;
    PERFORM 1 FROM __SCHEMA__.creative_execution_steps
     WHERE user_id=p_user_id AND job_id=o.job_id AND step_id=o.source_step_id FOR UPDATE;
    PERFORM 1 FROM __SCHEMA__.creative_execution_attempts
     WHERE user_id=p_user_id AND id=o.source_attempt_id FOR UPDATE;
    PERFORM 1 FROM __SCHEMA__.creative_craft_launcher_reservations
     WHERE user_id=p_user_id AND attempt_id=o.source_attempt_id FOR UPDATE;
    PERFORM 1 FROM __SCHEMA__.creative_runtime_reconciliation_outbox
     WHERE user_id=p_user_id AND attempt_id=o.source_attempt_id FOR UPDATE;
    SELECT user_id,source_attempt_id,job_id,source_step_id,attempt_no,
           claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,
           terminal_status,dispatch_id,request_sha256,authority_sha256,
           terminal_receipt_sha256,candidate_id,quarantine_set_sha256,
           adoption_attempt_id,adoption_fence_epoch,adoption_result_sha256,
           status,lease_token,lease_until,attempt_count,completed_at INTO ack FROM __SCHEMA__.creative_craft_launcher_ack_outbox
     WHERE user_id=p_user_id AND source_attempt_id=o.source_attempt_id FOR UPDATE;
    SELECT user_id,escrow_id,source_attempt_id,candidate_id,job_id,source_step_id,
           attempt_no,claim_lease_token,fence_epoch,admission_sha256,
           claim_set_sha256,terminal_status,dispatch_id,request_sha256,
           authority_sha256,escrow_manifest_sha256,escrow_manifest,state,
           version,lease_token,lease_until,attempt_count,available_at,created_at,
           quarantine_set_sha256,adoption_attempt_id,adoption_fence_epoch,
           adoption_result_sha256 INTO locked FROM __SCHEMA__.creative_craft_output_adoption_outbox
     WHERE user_id=p_user_id AND escrow_id=p_escrow_id FOR UPDATE;
    IF NOT FOUND OR locked.state<>'adopted' OR locked.version<>p_version
       OR locked IS DISTINCT FROM o THEN RETURN false; END IF;
    ack_exact := COALESCE(ack.status='done' AND ack.completed_at IS NOT NULL AND
       (ack.job_id,ack.source_step_id,ack.attempt_no,ack.claim_lease_token,
        ack.fence_epoch,ack.admission_sha256,ack.claim_set_sha256,
        ack.terminal_status,ack.dispatch_id,ack.request_sha256,ack.authority_sha256,
        ack.candidate_id,ack.quarantine_set_sha256,ack.adoption_attempt_id,
        ack.adoption_fence_epoch,ack.adoption_result_sha256) IS NOT DISTINCT FROM
       (o.job_id,o.source_step_id,o.attempt_no,o.claim_lease_token,
        o.fence_epoch,o.admission_sha256,o.claim_set_sha256,
        o.terminal_status,o.dispatch_id,o.request_sha256,o.authority_sha256,
        o.candidate_id,o.quarantine_set_sha256,o.adoption_attempt_id,
        o.adoption_fence_epoch,o.adoption_result_sha256),false);
    IF NOT ack_exact THEN
      SELECT cs.state,cs.quarantine_set_sha256,q.quarantine_set_sha256 AS quarantine_set_sha256_q,
             q.adoption_attempt_id,q.adoption_fence_epoch,q.adoption_result_sha256
        INTO cs
        FROM __SCHEMA__.creative_candidate_states cs
        JOIN __SCHEMA__.creative_candidate_quarantines q
          ON q.user_id=cs.user_id AND q.candidate_id=cs.candidate_id
       WHERE cs.user_id=p_user_id AND cs.candidate_id=o.candidate_id;
      IF NOT FOUND OR cs.state IS NULL OR cs.state NOT IN
           ('quarantined','review_pending','blocked','approved_for_use',
            'revision_requested','released')
         OR cs.quarantine_set_sha256 IS DISTINCT FROM o.quarantine_set_sha256
         OR (o.quarantine_set_sha256,o.adoption_attempt_id,o.adoption_fence_epoch,
             o.adoption_result_sha256) IS DISTINCT FROM
            (cs.quarantine_set_sha256_q,cs.adoption_attempt_id,
             cs.adoption_fence_epoch,cs.adoption_result_sha256)
         THEN RETURN false; END IF;
    END IF;
    UPDATE __SCHEMA__.creative_craft_output_adoption_outbox
       SET state='reconciliation_pending',version=version+1,updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND escrow_id=p_escrow_id AND state='adopted'
       AND version=p_version;
    RETURN FOUND;
END $body$;
$ddl$,'__SCHEMA__',quote_ident(s)),'__PREP_ROLE__',prep_role),'__ACK_ROLE__',ack_role),'__ESC_ROLE__',esc_role);

EXECUTE replace(replace(replace(replace($ddl$
CREATE OR REPLACE FUNCTION __SCHEMA__.creative_craft_escrow_defer_cleanup(
    p_user_id uuid,p_escrow_id uuid,p_version integer) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record;
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM '__ESC_ROLE__' THEN
        RAISE EXCEPTION 'Craft escrow role required' USING ERRCODE='42501';
    END IF;
    SELECT deletion_requested_at INTO u FROM __SCHEMA__.users
      WHERE id=p_user_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;
    UPDATE __SCHEMA__.creative_craft_output_adoption_outbox
       SET state='adopted',version=version+1,last_error='transition_failed',
           available_at=clock_timestamp()+interval '5 seconds',updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND escrow_id=p_escrow_id
       AND state='adopted' AND version=p_version;
    RETURN FOUND;
END $body$;
$ddl$,'__SCHEMA__',quote_ident(s)),'__PREP_ROLE__',prep_role),'__ACK_ROLE__',ack_role),'__ESC_ROLE__',esc_role);

EXECUTE replace(replace(replace(replace($ddl$
CREATE OR REPLACE FUNCTION __SCHEMA__.creative_craft_escrow_release(
    p_user_id uuid,p_escrow_id uuid,p_version integer,p_lease_token uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record; prior text;
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM '__ESC_ROLE__' THEN
        RAISE EXCEPTION 'Craft escrow role required' USING ERRCODE='42501';
    END IF;
    SELECT deletion_requested_at INTO u FROM __SCHEMA__.users
      WHERE id=p_user_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;
    SELECT state INTO prior FROM __SCHEMA__.creative_craft_output_adoption_outbox
     WHERE user_id=p_user_id AND escrow_id=p_escrow_id FOR UPDATE;
    IF prior NOT IN ('adopting','reconciling_cleanup') THEN RETURN false; END IF;
    UPDATE __SCHEMA__.creative_craft_output_adoption_outbox
       SET state=CASE prior WHEN 'adopting' THEN 'pending_adoption'
                            ELSE 'reconciliation_pending' END,
           version=version+1,lease_token=NULL,lease_until=NULL,
           last_error='transition_failed',available_at=clock_timestamp()+interval '5 seconds',
           updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND escrow_id=p_escrow_id AND state=prior
       AND version=p_version AND lease_token=p_lease_token
       AND lease_until>clock_timestamp();
    RETURN FOUND;
END $body$;
$ddl$,'__SCHEMA__',quote_ident(s)),'__PREP_ROLE__',prep_role),'__ACK_ROLE__',ack_role),'__ESC_ROLE__',esc_role);
END $migration$;

DO $privileges$
DECLARE s text:=current_schema();
        k text:=substr(md5(length(current_database())::text||':'||current_database()||':'||
          length(current_schema())::text||':'||current_schema()),1,24);
        prep_role text:='uonify_craft_prep_'||k;
        ack_role text:='uonify_craft_ack_'||k;
        esc_role text:='uonify_craft_esc_'||k;
        def_role text:='uonify_craft_def_'||k;
        fixed_roles text:='uonify_craft_launcher_preparer,uonify_craft_launcher_ack_worker,uonify_craft_escrow_worker,uonify_craft_transition_definer';
        f record; c record; contaminated text;
BEGIN
  -- Remove every local ACL left by 112 from the fixed bridge identities.  This
  -- intentionally makes no claim about dependencies in another database.
  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
      'creative_craft_preparer_claim_compensation',
      'creative_craft_preparer_release_compensation',
      'creative_craft_ack_claim','creative_craft_ack_release',
      'creative_craft_escrow_claim','creative_craft_escrow_shortlist',
      'creative_craft_escrow_schedule_cleanup',
      'creative_craft_escrow_defer_cleanup','creative_craft_escrow_release')
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.signature,def_role);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',f.signature,fixed_roles);
  END LOOP;
  EXECUTE format('DROP FUNCTION IF EXISTS %I.creative_craft_escrow_claim()',s);
  EXECUTE format('REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I FROM uonify_craft_transition_definer',s);
  FOR c IN SELECT table_name,column_name FROM information_schema.columns
            WHERE table_schema=s LOOP
    EXECUTE format('REVOKE ALL (%I) ON TABLE %I.%I FROM uonify_craft_transition_definer',
                   c.column_name,s,c.table_name);
  END LOOP;
  EXECUTE format('REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA %I FROM uonify_craft_transition_definer',s);
  EXECUTE format('REVOKE ALL PRIVILEGES ON SCHEMA %I FROM %s',s,fixed_roles);

  EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I',s,def_role);
  EXECUTE format('GRANT SELECT(id,deletion_requested_at),UPDATE(deletion_requested_at) ON %I.users TO %I',s,def_role);
  EXECUTE format('GRANT SELECT(id,user_id,status,job_id,step_id,attempt_no,lease_token,claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,lease_until,provider_started_at,provider_returned_at),UPDATE(status) ON %I.creative_execution_attempts TO %I',s,def_role);
  EXECUTE format('GRANT SELECT(id,user_id,status,lease_token,lease_until),UPDATE(status) ON %I.creative_execution_jobs TO %I',s,def_role);
  EXECUTE format('GRANT SELECT(user_id,job_id,step_id,status,kind,provider_call,lease_token,lease_until,provider_started_at,provider_returned_at),UPDATE(status) ON %I.creative_execution_steps TO %I',s,def_role);
  EXECUTE format('GRANT SELECT(user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,dispatch_id,request_sha256,authority_sha256,profile_sha256,input_root,output_root,reserved_at,compensation_status,compensation_lease_token,compensation_lease_until,compensation_attempt_count),UPDATE(compensation_status,compensation_lease_token,compensation_lease_until,compensation_attempt_count,compensation_last_error,updated_at) ON %I.creative_craft_launcher_reservations TO %I',s,def_role);
  EXECUTE format('GRANT SELECT(user_id,source_attempt_id,job_id,source_step_id,attempt_no,claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,terminal_status,dispatch_id,request_sha256,authority_sha256,terminal_receipt_sha256,candidate_id,quarantine_set_sha256,adoption_attempt_id,adoption_fence_epoch,adoption_result_sha256,status,lease_token,lease_until,attempt_count,completed_at),UPDATE(status,lease_token,lease_until,attempt_count,last_error,updated_at) ON %I.creative_craft_launcher_ack_outbox TO %I',s,def_role);
  EXECUTE format('GRANT SELECT(user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,terminal_status,status,lease_token,lease_until),UPDATE(status) ON %I.creative_runtime_reconciliation_outbox TO %I',s,def_role);
  EXECUTE format('GRANT SELECT(user_id,candidate_id,state,quarantine_set_sha256) ON %I.creative_candidate_states TO %I',s,def_role);
  EXECUTE format('GRANT SELECT(user_id,candidate_id,quarantine_set_sha256,adoption_attempt_id,adoption_fence_epoch,adoption_result_sha256) ON %I.creative_candidate_quarantines TO %I',s,def_role);
  EXECUTE format('GRANT SELECT(user_id,escrow_id,source_attempt_id,candidate_id,job_id,source_step_id,attempt_no,claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,terminal_status,dispatch_id,request_sha256,authority_sha256,escrow_manifest_sha256,escrow_manifest,state,version,lease_token,lease_until,attempt_count,available_at,created_at,quarantine_set_sha256,adoption_attempt_id,adoption_fence_epoch,adoption_result_sha256),UPDATE(state,version,lease_token,lease_until,attempt_count,last_error,available_at,updated_at) ON %I.creative_craft_output_adoption_outbox TO %I',s,def_role);

  -- Recheck at the grant boundary.  The advisory lock serializes cooperating
  -- migrators; this closes the remaining window for an unexpected privileged
  -- membership/capability change inside this transaction.
  SELECT string_agg(r.rolname,',' ORDER BY r.rolname) INTO contaminated
    FROM pg_roles r
   WHERE r.rolname=ANY(ARRAY[prep_role,ack_role,esc_role,def_role])
     AND (r.rolcanlogin OR r.rolinherit OR r.rolsuper OR r.rolcreatedb OR
          r.rolcreaterole OR r.rolreplication OR r.rolbypassrls OR
          EXISTS (SELECT 1 FROM pg_auth_members m
                   WHERE m.roleid=r.oid OR m.member=r.oid));
  IF contaminated IS NOT NULL THEN
    RAISE EXCEPTION 'scoped Craft role changed before transition grants: %',
      contaminated USING ERRCODE='55000';
  END IF;

  EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I,%I,%I',s,prep_role,ack_role,esc_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_preparer_claim_compensation(uuid,uuid),%I.creative_craft_preparer_release_compensation(uuid,uuid,uuid) TO %I',s,s,prep_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_ack_claim(uuid,uuid,uuid),%I.creative_craft_ack_release(uuid,uuid,uuid) TO %I',s,s,ack_role);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_escrow_shortlist(uuid),%I.creative_craft_escrow_claim(uuid,uuid),%I.creative_craft_escrow_schedule_cleanup(uuid,uuid,integer),%I.creative_craft_escrow_defer_cleanup(uuid,uuid,integer),%I.creative_craft_escrow_release(uuid,uuid,integer,uuid) TO %I',s,s,s,s,s,esc_role);
END $privileges$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM creative_craft_launcher_deployment_policies
             WHERE desired_active) OR
     EXISTS (SELECT 1 FROM creative_craft_transition_installation_bindings
             WHERE desired_active) THEN
    RAISE EXCEPTION 'Craft transition API cannot activate the launcher'
      USING ERRCODE='55000';
  END IF;
END $$;
