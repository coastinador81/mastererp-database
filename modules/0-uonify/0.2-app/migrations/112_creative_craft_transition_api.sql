-- Inactive, least-privilege transition API for the disconnected Craft launcher.
-- This migration does not integrate a caller, create a queue, enable a worker,
-- or change the desired_active=false deployment policy. Row materialization and every completion that attests external I/O for
-- reservations, ACKs and escrows remain explicit activation blockers: the
-- Python projections perform content validation that is not duplicated here.

SELECT pg_advisory_xact_lock(
    hashtextextended('uonify-craft-launcher-roles-v1',0));
SELECT pg_advisory_xact_lock(
    hashtextextended('uonify-craft-transition-api-v1',0));

DO $$
DECLARE dirty text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles
               WHERE rolname='uonify_craft_transition_definer') THEN
        SELECT 'membership' INTO dirty
         WHERE EXISTS (
            SELECT 1 FROM pg_auth_members m
            JOIN pg_roles r ON r.oid=m.roleid OR r.oid=m.member
            WHERE r.rolname='uonify_craft_transition_definer');
        IF dirty IS NULL THEN
            SELECT 'dependency' INTO dirty
             WHERE EXISTS (
                SELECT 1 FROM pg_shdepend d JOIN pg_roles r ON r.oid=d.refobjid
                 WHERE r.rolname='uonify_craft_transition_definer'
                   AND d.refclassid='pg_authid'::regclass
                   AND d.deptype IN ('a','o'));
        END IF;
        IF dirty IS NOT NULL THEN
            RAISE EXCEPTION 'pre-existing Craft transition definer is contaminated: %',dirty
                USING ERRCODE='55000';
        END IF;
    ELSE
        CREATE ROLE uonify_craft_transition_definer NOLOGIN NOINHERIT
            NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    END IF;
END $$;

ALTER ROLE uonify_craft_transition_definer NOLOGIN NOINHERIT
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

DO $migration$
DECLARE s text := current_schema();
BEGIN
EXECUTE replace($ddl$
CREATE FUNCTION __SCHEMA__.creative_craft_preparer_claim_compensation(
    p_user_id uuid,p_attempt_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record; seed record; j record; st record; a record; r record;
        token uuid:=gen_random_uuid();
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM 'uonify_craft_launcher_preparer' THEN
        RAISE EXCEPTION 'Craft preparer role required' USING ERRCODE='42501';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
      'uonify:craft-attempt:'||p_attempt_id::text,0));
    SELECT deletion_requested_at INTO u FROM __SCHEMA__.users
     WHERE id=p_user_id FOR NO KEY UPDATE;
    IF NOT FOUND OR u.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
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
$ddl$,'__SCHEMA__',quote_ident(s));

EXECUTE replace($ddl$
CREATE FUNCTION __SCHEMA__.creative_craft_preparer_release_compensation(
    p_user_id uuid,p_attempt_id uuid,p_lease_token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record;
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM 'uonify_craft_launcher_preparer' THEN
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
$ddl$,'__SCHEMA__',quote_ident(s));

EXECUTE replace($ddl$
CREATE FUNCTION __SCHEMA__.creative_craft_ack_claim(
    p_user_id uuid,p_attempt_id uuid,p_runtime_lease_token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record; a record; r record; runtime record; ack record;
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM 'uonify_craft_launcher_ack_worker' THEN
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
$ddl$,'__SCHEMA__',quote_ident(s));

EXECUTE replace($ddl$
CREATE FUNCTION __SCHEMA__.creative_craft_ack_release(
    p_user_id uuid,p_attempt_id uuid,p_runtime_lease_token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record; runtime record;
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM 'uonify_craft_launcher_ack_worker' THEN
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
$ddl$,'__SCHEMA__',quote_ident(s));

EXECUTE replace($ddl$
CREATE FUNCTION __SCHEMA__.creative_craft_escrow_claim() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE row record; u record; j record; st record; a record; r record; runtime record;
        token uuid:=gen_random_uuid();
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM 'uonify_craft_escrow_worker' THEN
        RAISE EXCEPTION 'Craft escrow role required' USING ERRCODE='42501';
    END IF;
    SELECT user_id,escrow_id,source_attempt_id,candidate_id,job_id,source_step_id,
           attempt_no,claim_lease_token,fence_epoch,admission_sha256,
           claim_set_sha256,terminal_status,dispatch_id,request_sha256,
           authority_sha256,escrow_manifest_sha256,escrow_manifest,state,
           version,lease_token,lease_until,attempt_count,available_at,created_at,
           quarantine_set_sha256,adoption_attempt_id,adoption_fence_epoch,
           adoption_result_sha256 INTO row FROM __SCHEMA__.creative_craft_output_adoption_outbox o
     WHERE o.available_at<=clock_timestamp()
       AND (o.state IN ('pending_adoption','reconciliation_pending') OR
           (o.state IN ('adopting','reconciling_cleanup') AND o.lease_until<=clock_timestamp()))
     ORDER BY o.created_at,o.user_id,o.escrow_id LIMIT 1;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT deletion_requested_at INTO u FROM __SCHEMA__.users
     WHERE id=row.user_id FOR NO KEY UPDATE;
    IF NOT FOUND OR u.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
    SELECT status INTO j FROM __SCHEMA__.creative_execution_jobs
     WHERE user_id=row.user_id AND id=row.job_id FOR UPDATE;
    SELECT status,kind,provider_call INTO st FROM __SCHEMA__.creative_execution_steps
     WHERE user_id=row.user_id AND job_id=row.job_id AND step_id=row.source_step_id FOR UPDATE;
    SELECT status,job_id,step_id,attempt_no,claim_lease_token,fence_epoch,
           admission_sha256,claim_set_sha256 INTO a
      FROM __SCHEMA__.creative_execution_attempts
     WHERE user_id=row.user_id AND id=row.source_attempt_id FOR UPDATE;
    SELECT compensation_status,job_id,step_id,attempt_no,claim_lease_token,
           fence_epoch,admission_sha256,claim_set_sha256,dispatch_id,
           request_sha256,authority_sha256 INTO r
      FROM __SCHEMA__.creative_craft_launcher_reservations
     WHERE user_id=row.user_id AND attempt_id=row.source_attempt_id FOR UPDATE;
    SELECT terminal_status INTO runtime
      FROM __SCHEMA__.creative_runtime_reconciliation_outbox
     WHERE user_id=row.user_id AND attempt_id=row.source_attempt_id FOR UPDATE;
    IF a.status<>'succeeded' OR st.kind<>'craft' OR NOT st.provider_call
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
     WHERE user_id=row.user_id AND escrow_id=row.escrow_id AND version=row.version
       AND available_at<=clock_timestamp()
       AND (state IN ('pending_adoption','reconciliation_pending') OR
           (state IN ('adopting','reconciling_cleanup') AND lease_until<=clock_timestamp()))
     RETURNING user_id,escrow_id,source_attempt_id,candidate_id,state,version,lease_token,attempt_count,escrow_manifest INTO row;
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('userId',row.user_id,'escrowId',row.escrow_id,
      'sourceAttemptId',row.source_attempt_id,'candidateId',row.candidate_id,
      'state',row.state,'version',row.version,'leaseToken',token,
      'escrowManifest',row.escrow_manifest);
END $body$;
$ddl$,'__SCHEMA__',quote_ident(s));

EXECUTE replace($ddl$
CREATE FUNCTION __SCHEMA__.creative_craft_escrow_schedule_cleanup(
    p_user_id uuid,p_escrow_id uuid,p_version integer) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record; o record; locked record; ack record; q record; cs record;
        ack_exact boolean:=false;
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM 'uonify_craft_escrow_worker' THEN
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
    IF NOT FOUND OR u.deletion_requested_at IS NOT NULL THEN RETURN false; END IF;
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
$ddl$,'__SCHEMA__',quote_ident(s));

EXECUTE replace($ddl$
CREATE FUNCTION __SCHEMA__.creative_craft_escrow_defer_cleanup(
    p_user_id uuid,p_escrow_id uuid,p_version integer) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record;
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM 'uonify_craft_escrow_worker' THEN
        RAISE EXCEPTION 'Craft escrow role required' USING ERRCODE='42501';
    END IF;
    SELECT deletion_requested_at INTO u FROM __SCHEMA__.users
      WHERE id=p_user_id FOR NO KEY UPDATE;
    IF NOT FOUND OR u.deletion_requested_at IS NOT NULL THEN RETURN false; END IF;
    UPDATE __SCHEMA__.creative_craft_output_adoption_outbox
       SET state='adopted',version=version+1,last_error='transition_failed',
           available_at=clock_timestamp()+interval '5 seconds',updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND escrow_id=p_escrow_id
       AND state='adopted' AND version=p_version;
    RETURN FOUND;
END $body$;
$ddl$,'__SCHEMA__',quote_ident(s));

EXECUTE replace($ddl$
CREATE FUNCTION __SCHEMA__.creative_craft_escrow_release(
    p_user_id uuid,p_escrow_id uuid,p_version integer,p_lease_token uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,__SCHEMA__,pg_temp AS $body$
DECLARE u record; prior text;
BEGIN
    IF current_setting('role',true) IS DISTINCT FROM 'uonify_craft_escrow_worker' THEN
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
$ddl$,'__SCHEMA__',quote_ident(s));
END $migration$;

DO $$ DECLARE s text:=current_schema(); BEGIN
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO uonify_craft_transition_definer',s);
    EXECUTE format('GRANT SELECT(id,deletion_requested_at),UPDATE(deletion_requested_at) ON %I.users TO uonify_craft_transition_definer',s);
    EXECUTE format('GRANT SELECT(id,user_id,status,job_id,step_id,attempt_no,lease_token,claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,lease_until,provider_started_at,provider_returned_at),UPDATE(status) ON %I.creative_execution_attempts TO uonify_craft_transition_definer',s);
    EXECUTE format('GRANT SELECT(id,user_id,status,lease_token,lease_until),UPDATE(status) ON %I.creative_execution_jobs TO uonify_craft_transition_definer',s);
    EXECUTE format('GRANT SELECT(user_id,job_id,step_id,status,kind,provider_call,lease_token,lease_until,provider_started_at,provider_returned_at),UPDATE(status) ON %I.creative_execution_steps TO uonify_craft_transition_definer',s);
    EXECUTE format('GRANT SELECT(user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,dispatch_id,request_sha256,authority_sha256,profile_sha256,input_root,output_root,reserved_at,compensation_status,compensation_lease_token,compensation_lease_until,compensation_attempt_count),UPDATE(compensation_status,compensation_lease_token,compensation_lease_until,compensation_attempt_count,compensation_last_error,updated_at) ON %I.creative_craft_launcher_reservations TO uonify_craft_transition_definer',s);
    EXECUTE format('GRANT SELECT(user_id,source_attempt_id,job_id,source_step_id,attempt_no,claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,terminal_status,dispatch_id,request_sha256,authority_sha256,terminal_receipt_sha256,candidate_id,quarantine_set_sha256,adoption_attempt_id,adoption_fence_epoch,adoption_result_sha256,status,lease_token,lease_until,attempt_count,completed_at),UPDATE(status,lease_token,lease_until,attempt_count,last_error,updated_at) ON %I.creative_craft_launcher_ack_outbox TO uonify_craft_transition_definer',s);
    EXECUTE format('GRANT SELECT(user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,terminal_status,status,lease_token,lease_until),UPDATE(status) ON %I.creative_runtime_reconciliation_outbox TO uonify_craft_transition_definer',s);
    EXECUTE format('GRANT SELECT(user_id,candidate_id,state,quarantine_set_sha256) ON %I.creative_candidate_states TO uonify_craft_transition_definer',s);
    EXECUTE format('GRANT SELECT(user_id,candidate_id,quarantine_set_sha256,adoption_attempt_id,adoption_fence_epoch,adoption_result_sha256) ON %I.creative_candidate_quarantines TO uonify_craft_transition_definer',s);
    EXECUTE format('GRANT SELECT(user_id,escrow_id,source_attempt_id,candidate_id,job_id,source_step_id,attempt_no,claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,terminal_status,dispatch_id,request_sha256,authority_sha256,escrow_manifest_sha256,escrow_manifest,state,version,lease_token,lease_until,attempt_count,available_at,created_at,quarantine_set_sha256,adoption_attempt_id,adoption_fence_epoch,adoption_result_sha256),UPDATE(state,version,lease_token,lease_until,attempt_count,last_error,available_at,updated_at) ON %I.creative_craft_output_adoption_outbox TO uonify_craft_transition_definer',s);
END $$;

DO $$
DECLARE contaminated text;
BEGIN
  SELECT string_agg(r.rolname,',' ORDER BY r.rolname) INTO contaminated
    FROM pg_roles r
   WHERE r.rolname IN ('uonify_craft_launcher_preparer',
                       'uonify_craft_launcher_ack_worker',
                       'uonify_craft_escrow_worker')
     AND (r.rolcanlogin OR r.rolinherit OR r.rolsuper OR r.rolcreatedb
          OR r.rolcreaterole OR r.rolreplication OR r.rolbypassrls
          OR EXISTS (SELECT 1 FROM pg_auth_members m
                      WHERE m.roleid=r.oid OR m.member=r.oid)
          OR EXISTS (SELECT 1 FROM pg_shdepend d
                      WHERE d.refclassid='pg_authid'::regclass
                        AND d.refobjid=r.oid AND d.deptype IN ('a','o')));
  IF contaminated IS NOT NULL THEN
    RAISE EXCEPTION 'Craft caller role changed before transition grants: %',contaminated
      USING ERRCODE='55000';
  END IF;
END $$;

DO $$ DECLARE s text:=current_schema(); f record; BEGIN
  -- Revoke every overload sharing an API name. Only the exact signatures below
  -- are granted, so a pre-created overload cannot inherit authority by prefix.
  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
      'creative_craft_preparer_claim_compensation',
      'creative_craft_preparer_release_compensation',
      'creative_craft_ack_claim','creative_craft_ack_release',
      'creative_craft_escrow_claim','creative_craft_escrow_schedule_cleanup',
      'creative_craft_escrow_defer_cleanup','creative_craft_escrow_release')
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO uonify_craft_transition_definer',f.signature);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,uonify_craft_launcher_preparer,uonify_craft_launcher_ack_worker,uonify_craft_escrow_worker',f.signature);
  END LOOP;
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO uonify_craft_launcher_preparer,uonify_craft_launcher_ack_worker,uonify_craft_escrow_worker',s);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_preparer_claim_compensation(uuid,uuid),%I.creative_craft_preparer_release_compensation(uuid,uuid,uuid) TO uonify_craft_launcher_preparer',s,s);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_ack_claim(uuid,uuid,uuid),%I.creative_craft_ack_release(uuid,uuid,uuid) TO uonify_craft_launcher_ack_worker',s,s);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_escrow_claim(),%I.creative_craft_escrow_schedule_cleanup(uuid,uuid,integer),%I.creative_craft_escrow_defer_cleanup(uuid,uuid,integer),%I.creative_craft_escrow_release(uuid,uuid,integer,uuid) TO uonify_craft_escrow_worker',s,s,s,s);
END $$;

-- The policy remains append-only and inactive. This assertion makes an
-- accidental activation in the same migration fail atomically.
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM creative_craft_launcher_deployment_policies WHERE desired_active) THEN
   RAISE EXCEPTION 'Craft transition API cannot activate the launcher' USING ERRCODE='55000';
 END IF;
END $$;
