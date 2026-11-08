-- Inactive, installation-scoped physical evidence and transition authority.
--
-- This gate installs no worker, route, credential or scheduler.  Every caller
-- role remains NOLOGIN/NOINHERIT and the binding remains desired_active=false.
-- Physical observations are separated from business-state completion: an
-- issue routine freezes a server-derived challenge, a scoped verifier attests
-- only that challenge, and a completion consumes the immutable receipt under
-- the original account/fence/lease CAS.  Completion routines accept no JSON or
-- caller-authored digest.

SELECT pg_advisory_xact_lock(hashtextextended('uonify-craft-launcher-roles-v1',0));
SELECT pg_advisory_xact_lock(hashtextextended('uonify-craft-transition-api-v1',0));
SELECT pg_advisory_xact_lock(hashtextextended('uonify-craft-transition-api-v2',0));
SELECT pg_advisory_xact_lock(hashtextextended('uonify-craft-physical-api-v1',0));

-- A physical reserve can exist before its SQL completion is committed.  Gate
-- 109 only modelled cleanup before reserve, so extend that forward-only state
-- machine: an expired confirmed reservation may enter physical cleanup and a
-- persisted reserve proof may be forgotten before it becomes `reserved_at`.
ALTER TABLE creative_craft_launcher_reservations
  DROP CONSTRAINT creative_craft_launcher_compensation_confirmed_check,
  ADD CONSTRAINT creative_craft_launcher_compensation_confirmed_check
    CHECK (compensation_status<>'confirmed' OR reserved_at IS NOT NULL);

CREATE OR REPLACE FUNCTION creative_craft_launcher_reservation_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (OLD.user_id,OLD.attempt_id,OLD.job_id,OLD.step_id,OLD.attempt_no,
      OLD.claim_lease_token,OLD.fence_epoch,OLD.admission_id,
      OLD.admission_sha256,OLD.claim_set_sha256,OLD.dispatch_id,
      OLD.request_sha256,OLD.request_authority,OLD.profile_id,
      OLD.profile_sha256,OLD.control_document,OLD.input_root,OLD.output_root,
      OLD.inputs,OLD.expected_outputs,OLD.limits,OLD.authority_sha256,
      OLD.prepared_at) IS DISTINCT FROM
     (NEW.user_id,NEW.attempt_id,NEW.job_id,NEW.step_id,NEW.attempt_no,
      NEW.claim_lease_token,NEW.fence_epoch,NEW.admission_id,
      NEW.admission_sha256,NEW.claim_set_sha256,NEW.dispatch_id,
      NEW.request_sha256,NEW.request_authority,NEW.profile_id,
      NEW.profile_sha256,NEW.control_document,NEW.input_root,NEW.output_root,
      NEW.inputs,NEW.expected_outputs,NEW.limits,NEW.authority_sha256,
      NEW.prepared_at) THEN
    RAISE EXCEPTION 'creative craft launcher authority is immutable';
  END IF;
  IF OLD.compensation_attempt_count>NEW.compensation_attempt_count THEN
    RAISE EXCEPTION 'creative craft launcher compensation attempts are monotonic';
  END IF;
  IF OLD.reserved_at IS NOT NULL AND
     (OLD.reservation_receipt,OLD.reservation_receipt_sha256,OLD.reserved_at)
     IS DISTINCT FROM
     (NEW.reservation_receipt,NEW.reservation_receipt_sha256,NEW.reserved_at) THEN
    RAISE EXCEPTION 'creative craft launcher reserve receipt is immutable';
  END IF;
  IF OLD.compensation_status='compensated' AND OLD IS DISTINCT FROM NEW THEN
    RAISE EXCEPTION 'terminal creative craft launcher preparation is immutable';
  END IF;
  IF NOT (
      (OLD.compensation_status='pending'
       AND NEW.compensation_status IN ('running','confirmed')) OR
      (OLD.compensation_status='confirmed'
       AND NEW.compensation_status='running') OR
      (OLD.compensation_status='running'
       AND NEW.compensation_status IN ('running','compensated'))
  ) THEN
    RAISE EXCEPTION 'invalid creative craft launcher compensation transition';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION creative_craft_launcher_reservation_write_allowed()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE deleting timestamptz;
BEGIN
  SELECT deletion_requested_at INTO deleting FROM users WHERE id=NEW.user_id;
  IF deleting IS NULL THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' AND OLD.user_id=NEW.user_id
     AND ((OLD.compensation_status='pending'
           AND NEW.compensation_status='running') OR
          (OLD.compensation_status='confirmed'
           AND NEW.compensation_status='running') OR
          (OLD.compensation_status='running'
           AND NEW.compensation_status IN ('running','compensated'))) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Account deletion pending' USING ERRCODE='55000';
END $$;

ALTER TABLE creative_craft_transition_installation_bindings
  ADD COLUMN installation_id uuid NOT NULL DEFAULT gen_random_uuid(),
  ADD CONSTRAINT creative_craft_transition_installation_id_unique
    UNIQUE(installation_id);

CREATE TABLE creative_craft_physical_installation_bindings (
  installation_id uuid PRIMARY KEY,
  installation_key text NOT NULL UNIQUE,
  database_name text NOT NULL,
  schema_name text NOT NULL,
  launcher_verifier_role text NOT NULL UNIQUE,
  storage_verifier_role text NOT NULL UNIQUE,
  receipt_definer_role text NOT NULL UNIQUE,
  completion_definer_role text NOT NULL UNIQUE,
  verifier_policy_sha256 text NOT NULL CHECK (verifier_policy_sha256 ~ '^[0-9a-f]{64}$'),
  desired_active boolean NOT NULL DEFAULT false CHECK (NOT desired_active),
  authority_mode text NOT NULL DEFAULT 'security_definer_only_inactive'
    CHECK (authority_mode='security_definer_only_inactive'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (installation_key)
    REFERENCES creative_craft_transition_installation_bindings(installation_key),
  UNIQUE(database_name,schema_name),
  CHECK (launcher_verifier_role<>storage_verifier_role),
  CHECK (receipt_definer_role<>completion_definer_role)
);

CREATE FUNCTION creative_craft_physical_binding_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  RAISE EXCEPTION 'Craft physical installation binding is append-only'
    USING ERRCODE='55000';
END $$;
CREATE TRIGGER creative_craft_physical_binding_append_only
BEFORE UPDATE OR DELETE ON creative_craft_physical_installation_bindings
FOR EACH ROW EXECUTE FUNCTION creative_craft_physical_binding_append_only();

DO $roles$
DECLARE s text:=current_schema(); k text; installation uuid;
        role_name text; dirty text;
        roles text[];
BEGIN
  SELECT installation_key,installation_id INTO k,installation
    FROM creative_craft_transition_installation_bindings
   WHERE database_name=current_database() AND schema_name=s;
  IF k IS NULL THEN
    RAISE EXCEPTION 'Craft transition installation binding missing'
      USING ERRCODE='55000';
  END IF;
  roles:=ARRAY['uonify_craft_vlaunch_'||k,'uonify_craft_vstore_'||k,
               'uonify_craft_physdef_'||k,'uonify_craft_compdef_'||k];
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
                       AND d.refobjid=r.oid AND d.deptype IN ('a','o'))
          THEN 'dependency' END
        INTO dirty FROM pg_roles r WHERE r.rolname=role_name;
      IF dirty IS NOT NULL THEN
        RAISE EXCEPTION 'pre-existing physical Craft role contaminated: % (%)',
          role_name,dirty USING ERRCODE='55000';
      END IF;
    ELSE
      EXECUTE format('CREATE ROLE %I NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',role_name);
    END IF;
    EXECUTE format('ALTER ROLE %I NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',role_name);
  END LOOP;
  INSERT INTO creative_craft_physical_installation_bindings(
    installation_id,installation_key,database_name,schema_name,
    launcher_verifier_role,storage_verifier_role,receipt_definer_role,
    completion_definer_role,verifier_policy_sha256)
  VALUES(installation,k,current_database(),s,roles[1],roles[2],roles[3],roles[4],
    encode(sha256(convert_to('uonify-craft-physical-receipt-v2','UTF8')),'hex'));
END $roles$;

CREATE FUNCTION creative_craft_canonical_json(value jsonb) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE result text;
BEGIN
  CASE jsonb_typeof(value)
    WHEN 'object' THEN
      SELECT '{'||coalesce(string_agg(to_jsonb(key)::text||':'||
        creative_craft_canonical_json(item),',' ORDER BY key),'')||'}'
        INTO result FROM jsonb_each(value) AS fields(key,item);
    WHEN 'array' THEN
      SELECT '['||coalesce(string_agg(creative_craft_canonical_json(item),','
        ORDER BY ordinal),'')||']' INTO result
        FROM jsonb_array_elements(value) WITH ORDINALITY AS items(item,ordinal);
    ELSE result:=value::text;
  END CASE;
  RETURN result;
END $$;

CREATE FUNCTION creative_craft_json_sha256(value jsonb) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT encode(sha256(convert_to(creative_craft_canonical_json($1),'UTF8')),'hex')
$$;
CREATE FUNCTION creative_craft_text_sha256(value text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT encode(sha256(convert_to($1,'UTF8')),'hex')
$$;
CREATE FUNCTION creative_craft_account_advisory_key(owner_id uuid) RETURNS bigint
LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog AS $$
  SELECT hashtextextended('uonify:account:'||$1::text,0)
$$;
CREATE FUNCTION creative_craft_attempt_advisory_key(attempt_id uuid) RETURNS bigint
LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog AS $$
  SELECT hashtextextended('uonify:craft-attempt:'||$1::text,0)
$$;

CREATE TABLE creative_craft_physical_challenges (
  user_id uuid NOT NULL,
  challenge_id uuid NOT NULL DEFAULT gen_random_uuid(),
  receipt_id uuid NOT NULL DEFAULT gen_random_uuid(),
  installation_id uuid NOT NULL,
  phase text NOT NULL CHECK (phase IN
    ('reserve','prestart_forget','terminal_forget','adopt_copy')),
  attempt_id uuid NOT NULL,
  escrow_id uuid,
  target_version integer CHECK (target_version IS NULL OR target_version>0),
  target_lease_token uuid,
  binding jsonb NOT NULL CHECK (jsonb_typeof(binding)='object'),
  evidence jsonb NOT NULL CHECK (jsonb_typeof(evidence)='object'),
  verifier_proof jsonb NOT NULL CHECK (jsonb_typeof(verifier_proof)='object'),
  issued_role text NOT NULL,
  issued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(user_id,challenge_id),
  UNIQUE(challenge_id),
  UNIQUE(receipt_id),
  UNIQUE NULLS NOT DISTINCT
    (user_id,phase,attempt_id,escrow_id,target_version,target_lease_token),
  FOREIGN KEY(user_id) REFERENCES users(id),
  FOREIGN KEY(installation_id)
    REFERENCES creative_craft_physical_installation_bindings(installation_id),
  CHECK ((phase='adopt_copy')=(escrow_id IS NOT NULL)),
  CHECK ((phase='adopt_copy')=(target_version IS NOT NULL)),
  CHECK ((phase IN ('prestart_forget','terminal_forget','adopt_copy'))=
         (target_lease_token IS NOT NULL))
);

CREATE TABLE creative_craft_physical_receipts (
  user_id uuid NOT NULL,
  receipt_id uuid NOT NULL,
  challenge_id uuid NOT NULL,
  installation_id uuid NOT NULL,
  phase text NOT NULL CHECK (phase IN
    ('reserve','prestart_forget','terminal_forget','adopt_copy')),
  body jsonb NOT NULL CHECK (jsonb_typeof(body)='object'),
  receipt_sha256 text NOT NULL CHECK (receipt_sha256 ~ '^[0-9a-f]{64}$'),
  observed_at timestamptz NOT NULL,
  verifier_role text NOT NULL,
  PRIMARY KEY(user_id,receipt_id),
  UNIQUE(user_id,challenge_id),
  FOREIGN KEY(user_id,challenge_id)
    REFERENCES creative_craft_physical_challenges(user_id,challenge_id),
  FOREIGN KEY(installation_id)
    REFERENCES creative_craft_physical_installation_bindings(installation_id)
);

CREATE TABLE creative_craft_physical_receipt_consumptions (
  user_id uuid NOT NULL,
  receipt_id uuid NOT NULL,
  completion_kind text NOT NULL CHECK (completion_kind IN
    ('reservation','reservation_rejected','compensation','compensation_rejected',
     'ack','ack_rejected','adoption','adoption_rejected','cleanup')),
  attempt_id uuid NOT NULL,
  escrow_id uuid,
  target_version integer CHECK (target_version IS NULL OR target_version>0),
  consumed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(user_id,receipt_id,completion_kind),
  FOREIGN KEY(user_id,receipt_id)
    REFERENCES creative_craft_physical_receipts(user_id,receipt_id),
  CHECK ((completion_kind IN ('adoption','adoption_rejected','cleanup'))=
         (escrow_id IS NOT NULL))
);
CREATE UNIQUE INDEX creative_craft_physical_one_applied_completion
  ON creative_craft_physical_receipt_consumptions
    (user_id,completion_kind,attempt_id,escrow_id) NULLS NOT DISTINCT
  WHERE completion_kind IN
    ('reservation','compensation','ack','adoption','cleanup');

CREATE FUNCTION creative_craft_physical_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE deleting text:=current_setting('uonify.deleting_user',true);
BEGIN
  IF TG_OP='DELETE' AND deleting IS NOT NULL AND deleting=OLD.user_id::text
     AND EXISTS (SELECT 1 FROM users
                  WHERE id=OLD.user_id AND deletion_requested_at IS NOT NULL)
  THEN RETURN OLD; END IF;
  RAISE EXCEPTION 'Craft physical evidence is append-only' USING ERRCODE='55000';
END $$;
CREATE TRIGGER creative_craft_physical_challenges_append_only
BEFORE UPDATE OR DELETE ON creative_craft_physical_challenges
FOR EACH ROW EXECUTE FUNCTION creative_craft_physical_append_only();
CREATE TRIGGER creative_craft_physical_receipts_append_only
BEFORE UPDATE OR DELETE ON creative_craft_physical_receipts
FOR EACH ROW EXECUTE FUNCTION creative_craft_physical_append_only();
CREATE TRIGGER creative_craft_physical_consumptions_append_only
BEFORE UPDATE OR DELETE ON creative_craft_physical_receipt_consumptions
FOR EACH ROW EXECUTE FUNCTION creative_craft_physical_append_only();

CREATE FUNCTION creative_craft_expected_role(kind text) RETURNS text
LANGUAGE sql STABLE STRICT AS $$
  SELECT CASE $1
    WHEN 'preparer' THEN transition.preparer_role
    WHEN 'ack' THEN transition.ack_role
    WHEN 'escrow' THEN transition.escrow_role
    WHEN 'launcher_verifier' THEN physical.launcher_verifier_role
    WHEN 'storage_verifier' THEN physical.storage_verifier_role END
  FROM creative_craft_transition_installation_bindings transition
  JOIN creative_craft_physical_installation_bindings physical
    USING(installation_key)
  WHERE transition.database_name=current_database()
    AND transition.schema_name=(SELECT schema_name FROM
      creative_craft_physical_installation_bindings LIMIT 1)
$$;

CREATE FUNCTION creative_craft_require_role(kind text) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE expected text;
BEGIN
  expected:=creative_craft_expected_role(kind);
  IF expected IS NULL OR current_setting('role',true) IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'scoped Craft role required' USING ERRCODE='42501';
  END IF;
END $$;

CREATE FUNCTION creative_craft_account_deletion_barrier(p_user_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE present boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT true INTO present FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  RETURN coalesce(present,false);
END $$;

CREATE FUNCTION creative_craft_account_deletion_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.deletion_requested_at IS NULL AND NEW.deletion_requested_at IS NOT NULL
     AND NOT pg_try_advisory_xact_lock(
       creative_craft_account_advisory_key(NEW.id)) THEN
    RAISE EXCEPTION 'Craft account transition in progress'
      USING ERRCODE='40001';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER creative_craft_account_deletion_guard
BEFORE UPDATE OF deletion_requested_at ON users
FOR EACH ROW EXECUTE FUNCTION creative_craft_account_deletion_guard();

-- The remaining routines are deliberately created with caller-specific names.
-- Internal helpers are not granted to any caller role.

CREATE FUNCTION creative_craft_issue_reserve_challenge(
  p_user_id uuid,p_attempt_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; a record; r record; i record; challenge uuid:=gen_random_uuid();
        receipt uuid:=gen_random_uuid(); binding jsonb; evidence jsonb; row record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR u.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO a FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO r FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT p.installation_id,p.verifier_policy_sha256,
         t.preparer_role INTO i
    FROM creative_craft_physical_installation_bindings p
    JOIN creative_craft_transition_installation_bindings t USING(installation_key);
  IF a.id IS NULL OR r.attempt_id IS NULL OR a.status<>'running'
     OR a.provider_started_at IS NOT NULL OR a.provider_returned_at IS NOT NULL
     OR r.reserved_at IS NOT NULL OR r.compensation_status<>'pending'
     OR jsonb_array_length(r.expected_outputs)<1 THEN RETURN NULL; END IF;
  binding:=jsonb_build_object(
    'installationId',i.installation_id::text,
    'verifierPolicySha256',i.verifier_policy_sha256,
    'ownerUserId',p_user_id::text,'jobId',a.job_id::text,
    'stepId',a.step_id::text,'attemptId',a.id::text,
    'attemptNo',a.attempt_no,
    'claimLeaseTokenSha256',creative_craft_text_sha256(a.claim_lease_token::text),
    'fenceEpoch',a.fence_epoch,'admissionSha256',a.admission_sha256,
    'claimSetSha256',a.claim_set_sha256,'dispatchId',r.dispatch_id::text,
    'requestSha256',r.request_sha256,'authoritySha256',r.authority_sha256);
  evidence:=jsonb_build_object(
    'materializationSha256',creative_craft_json_sha256(jsonb_build_object(
      'inputRoot',r.input_root,'outputRoot',r.output_root,'inputs',r.inputs,
      'expectedOutputs',r.expected_outputs,'limits',r.limits)),
    'inputTreeSha256',creative_craft_json_sha256(r.inputs),
    'outputTreeSha256',creative_craft_json_sha256(r.expected_outputs),
    'ownershipMarkerSha256',creative_craft_json_sha256(jsonb_build_object(
      'ownerUserId',p_user_id::text,'attemptId',p_attempt_id::text,
      'inputRoot',r.input_root,'outputRoot',r.output_root)),
    'inputCount',jsonb_array_length(r.inputs),
    'expectedOutputCount',jsonb_array_length(r.expected_outputs));
  INSERT INTO creative_craft_physical_challenges(
    user_id,challenge_id,receipt_id,installation_id,phase,attempt_id,
    binding,evidence,verifier_proof,issued_role)
  VALUES(p_user_id,challenge,receipt,i.installation_id,'reserve',p_attempt_id,
         binding,evidence,jsonb_build_object('inputRoot',r.input_root,
           'outputRoot',r.output_root,'inputs',r.inputs,
           'expectedOutputs',r.expected_outputs,'limits',r.limits),
         current_setting('role',true))
  ON CONFLICT DO NOTHING;
  SELECT * INTO row FROM creative_craft_physical_challenges
   WHERE user_id=p_user_id AND phase='reserve' AND attempt_id=p_attempt_id
   ORDER BY issued_at DESC LIMIT 1;
  RETURN jsonb_build_object('challengeId',row.challenge_id::text,
    'receiptId',row.receipt_id::text,'phase',row.phase,
    'binding',row.binding,'evidence',row.evidence,'proof',row.verifier_proof);
END $$;

CREATE FUNCTION creative_craft_issue_prestart_forget_challenge(
  p_user_id uuid,p_attempt_id uuid,p_lease_token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; a record; r record; i record; challenge uuid:=gen_random_uuid();
        receipt uuid:=gen_random_uuid(); binding jsonb; evidence jsonb; row record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO a FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO r FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT p.installation_id,p.verifier_policy_sha256 INTO i
    FROM creative_craft_physical_installation_bindings p;
  IF a.id IS NULL OR r.attempt_id IS NULL
     OR a.provider_started_at IS NOT NULL OR a.provider_returned_at IS NOT NULL
     OR r.compensation_status<>'running'
     OR r.compensation_lease_token<>p_lease_token
     OR r.compensation_lease_until<=clock_timestamp() THEN RETURN NULL; END IF;
  binding:=jsonb_build_object('installationId',i.installation_id::text,
    'verifierPolicySha256',i.verifier_policy_sha256,
    'ownerUserId',p_user_id::text,'jobId',a.job_id::text,
    'stepId',a.step_id::text,'attemptId',a.id::text,'attemptNo',a.attempt_no,
    'claimLeaseTokenSha256',creative_craft_text_sha256(a.claim_lease_token::text),
    'fenceEpoch',a.fence_epoch,'admissionSha256',a.admission_sha256,
    'claimSetSha256',a.claim_set_sha256,'dispatchId',r.dispatch_id::text,
    'requestSha256',r.request_sha256,'authoritySha256',r.authority_sha256);
  evidence:=jsonb_build_object(
    'materializationSha256',creative_craft_json_sha256(jsonb_build_object(
      'inputRoot',r.input_root,'outputRoot',r.output_root,'inputs',r.inputs,
      'expectedOutputs',r.expected_outputs,'limits',r.limits)),
    'beforeTreeSha256',creative_craft_json_sha256(jsonb_build_object(
      'inputs',r.inputs,'expectedOutputs',r.expected_outputs)),
    'tombstoneSha256',creative_craft_json_sha256(jsonb_build_object(
      'schemaVersion',2,'phase','prestart_forget','dispatchId',r.dispatch_id::text,
      'requestSha256',r.request_sha256,'leaseToken',p_lease_token::text)),
    'journalEntrySha256',creative_craft_json_sha256(jsonb_build_object(
      'schemaVersion',1,'action','forget','attemptId',p_attempt_id::text,
      'leaseToken',p_lease_token::text)));
  INSERT INTO creative_craft_physical_challenges(
    user_id,challenge_id,receipt_id,installation_id,phase,attempt_id,
    target_lease_token,binding,evidence,verifier_proof,issued_role)
  VALUES(p_user_id,challenge,receipt,i.installation_id,'prestart_forget',
    p_attempt_id,p_lease_token,binding,evidence,
    jsonb_build_object('inputRoot',r.input_root,'outputRoot',r.output_root,
      'inputs',r.inputs,'expectedOutputs',r.expected_outputs,'limits',r.limits),
    current_setting('role',true))
  ON CONFLICT DO NOTHING;
  SELECT * INTO row FROM creative_craft_physical_challenges
   WHERE user_id=p_user_id AND phase='prestart_forget'
     AND attempt_id=p_attempt_id AND target_lease_token=p_lease_token
   ORDER BY issued_at DESC LIMIT 1;
  RETURN jsonb_build_object('challengeId',row.challenge_id::text,
    'receiptId',row.receipt_id::text,'phase',row.phase,
    'binding',row.binding,'evidence',row.evidence,'proof',row.verifier_proof);
END $$;

CREATE FUNCTION creative_craft_issue_terminal_forget_challenge(
  p_user_id uuid,p_attempt_id uuid,p_runtime_lease_token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; a record; r record; runtime record; ack record; i record;
        challenge uuid:=gen_random_uuid(); receipt uuid:=gen_random_uuid();
        binding jsonb; evidence jsonb; row record;
BEGIN
  PERFORM creative_craft_require_role('ack');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO a FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO r FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT * INTO runtime FROM creative_runtime_reconciliation_outbox
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT * INTO ack FROM creative_craft_launcher_ack_outbox
   WHERE user_id=p_user_id AND source_attempt_id=p_attempt_id FOR UPDATE;
  SELECT installation_id,verifier_policy_sha256 INTO i
    FROM creative_craft_physical_installation_bindings;
  IF a.status NOT IN ('succeeded','failed','cancelled') OR r.reserved_at IS NULL
     OR runtime.status<>'running' OR runtime.lease_token<>p_runtime_lease_token
     OR runtime.lease_until<=clock_timestamp() OR ack.status<>'running'
     OR ack.lease_token<>p_runtime_lease_token OR ack.lease_until<=clock_timestamp()
     OR ack.terminal_status<>a.status THEN RETURN NULL; END IF;
  binding:=jsonb_build_object('installationId',i.installation_id::text,
    'verifierPolicySha256',i.verifier_policy_sha256,
    'ownerUserId',p_user_id::text,'jobId',a.job_id::text,
    'stepId',a.step_id::text,'attemptId',a.id::text,'attemptNo',a.attempt_no,
    'claimLeaseTokenSha256',creative_craft_text_sha256(a.claim_lease_token::text),
    'fenceEpoch',a.fence_epoch,'admissionSha256',a.admission_sha256,
    'claimSetSha256',a.claim_set_sha256,'dispatchId',r.dispatch_id::text,
    'requestSha256',r.request_sha256,'authoritySha256',r.authority_sha256);
  evidence:=jsonb_build_object(
    'materializationSha256',creative_craft_json_sha256(jsonb_build_object(
      'inputRoot',r.input_root,'outputRoot',r.output_root,'inputs',r.inputs,
      'expectedOutputs',r.expected_outputs,'limits',r.limits)),
    'beforeTreeSha256',creative_craft_json_sha256(jsonb_build_object(
      'inputs',r.inputs,'expectedOutputs',r.expected_outputs)),
    'terminalStatus',a.status,'terminalReceiptSha256',ack.terminal_receipt_sha256,
    'tombstoneSha256',creative_craft_json_sha256(jsonb_build_object(
      'schemaVersion',2,'phase','terminal_forget','dispatchId',r.dispatch_id::text,
      'terminalStatus',a.status,'runtimeLeaseToken',p_runtime_lease_token::text)),
    'journalEntrySha256',creative_craft_json_sha256(jsonb_build_object(
      'schemaVersion',1,'action','terminal_forget','attemptId',p_attempt_id::text,
      'runtimeLeaseToken',p_runtime_lease_token::text)));
  INSERT INTO creative_craft_physical_challenges(
    user_id,challenge_id,receipt_id,installation_id,phase,attempt_id,
    target_lease_token,binding,evidence,verifier_proof,issued_role)
  VALUES(p_user_id,challenge,receipt,i.installation_id,'terminal_forget',
    p_attempt_id,p_runtime_lease_token,binding,evidence,
    jsonb_build_object('inputRoot',r.input_root,'outputRoot',r.output_root,
      'inputs',r.inputs,'expectedOutputs',r.expected_outputs,'limits',r.limits),
    current_setting('role',true))
  ON CONFLICT DO NOTHING;
  SELECT * INTO row FROM creative_craft_physical_challenges
   WHERE user_id=p_user_id AND phase='terminal_forget'
     AND attempt_id=p_attempt_id AND target_lease_token=p_runtime_lease_token
   ORDER BY issued_at DESC LIMIT 1;
  RETURN jsonb_build_object('challengeId',row.challenge_id::text,
    'receiptId',row.receipt_id::text,'phase',row.phase,
    'binding',row.binding,'evidence',row.evidence,'proof',row.verifier_proof);
END $$;

CREATE FUNCTION creative_craft_issue_adopt_copy_challenge(
  p_user_id uuid,p_escrow_id uuid,p_version integer,p_lease_token uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; o record; a record; q record; i record; artifacts jsonb;
        proof_items jsonb;
        challenge uuid:=gen_random_uuid(); receipt uuid:=gen_random_uuid();
        binding jsonb; evidence jsonb; row record;
BEGIN
  PERFORM creative_craft_require_role('escrow');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR u.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  SELECT * INTO o FROM creative_craft_output_adoption_outbox
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(o.source_attempt_id));
  SELECT * INTO a FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=o.source_attempt_id FOR UPDATE;
  SELECT * INTO o FROM creative_craft_output_adoption_outbox
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id FOR UPDATE;
  SELECT * INTO q FROM creative_candidate_quarantines
   WHERE user_id=p_user_id AND candidate_id=o.candidate_id FOR SHARE;
  SELECT installation_id,verifier_policy_sha256 INTO i
    FROM creative_craft_physical_installation_bindings;
  IF o.state<>'adopting' OR o.version<>p_version OR o.lease_token<>p_lease_token
     OR o.lease_until<=clock_timestamp() OR q.candidate_id IS NULL THEN RETURN NULL; END IF;
  SELECT jsonb_agg(destination ORDER BY ordinal) INTO proof_items FROM (
    SELECT asset.ordinal,jsonb_build_object('ordinal',asset.ordinal,
      'storageReceipt',asset.storage_receipt) AS destination
      FROM creative_candidate_quarantine_assets asset
     WHERE asset.user_id=p_user_id AND asset.candidate_id=o.candidate_id
    UNION ALL
    SELECT q.item_count,jsonb_build_object('ordinal',q.item_count,
      'storageReceipt',jsonb_build_object(
        'bucket',revision.storage_bucket,'name',revision.storage_name,
        'generation',revision.storage_generation,
        'mimeType',revision.mime_type,'byteSize',revision.byte_size,
        'sha256',revision.sha256))
      FROM creative_candidate_native_projects link
      JOIN creative_native_project_revisions revision
        ON revision.user_id=link.user_id AND revision.project_id=link.project_id
       AND revision.revision=link.revision
     WHERE link.user_id=p_user_id AND link.candidate_id=o.candidate_id
       AND o.engine IN ('filmcraft','photocraft')
  ) destinations;
  SELECT jsonb_agg(jsonb_build_object(
      'ordinal',(manifest.ordinality-1)::integer,
      'byteSize',(destination.value#>>'{storageReceipt,byteSize}')::bigint,
      'sha256',destination.value#>>'{storageReceipt,sha256}',
      'destinationReceiptSha256',creative_craft_json_sha256(
        destination.value->'storageReceipt')) ORDER BY manifest.ordinality)
    INTO artifacts
    FROM jsonb_array_elements(o.escrow_manifest->'artifacts')
           WITH ORDINALITY manifest(value,ordinality)
    JOIN jsonb_array_elements(proof_items) destination(value)
      ON (destination.value->>'ordinal')::integer=manifest.ordinality-1
   WHERE destination.value#>>'{storageReceipt,mimeType}'=
           manifest.value->>'mimeType'
     AND (destination.value#>>'{storageReceipt,byteSize}')::bigint=
           (manifest.value->>'byteSize')::bigint
     AND destination.value#>>'{storageReceipt,sha256}'=manifest.value->>'sha256';
  IF artifacts IS NULL
     OR jsonb_array_length(artifacts)<>
        jsonb_array_length(o.escrow_manifest->'artifacts')
     OR jsonb_array_length(proof_items)<>
        jsonb_array_length(o.escrow_manifest->'artifacts') THEN RETURN NULL; END IF;
  binding:=jsonb_build_object('installationId',i.installation_id::text,
    'verifierPolicySha256',i.verifier_policy_sha256,
    'ownerUserId',p_user_id::text,'jobId',a.job_id::text,
    'stepId',a.step_id::text,'attemptId',a.id::text,'attemptNo',a.attempt_no,
    'claimLeaseTokenSha256',creative_craft_text_sha256(a.claim_lease_token::text),
    'fenceEpoch',a.fence_epoch,'admissionSha256',a.admission_sha256,
    'claimSetSha256',a.claim_set_sha256,'dispatchId',o.dispatch_id::text,
    'requestSha256',o.request_sha256,'authoritySha256',o.authority_sha256);
  evidence:=jsonb_build_object('escrowId',o.escrow_id::text,
    'manifestSha256',o.escrow_manifest_sha256,'candidateId',o.candidate_id::text,
    'artifactManifestSha256',o.artifact_manifest_sha256,
    'quarantineSetSha256',q.quarantine_set_sha256,
    'adoptionAttemptId',q.adoption_attempt_id::text,
    'adoptionFenceEpoch',q.adoption_fence_epoch,
    'adoptionResultSha256',q.adoption_result_sha256,
    'artifacts',artifacts,'copySetSha256',creative_craft_json_sha256(artifacts));
  INSERT INTO creative_craft_physical_challenges(
    user_id,challenge_id,receipt_id,installation_id,phase,attempt_id,escrow_id,
    target_version,target_lease_token,binding,evidence,verifier_proof,issued_role)
  VALUES(p_user_id,challenge,receipt,i.installation_id,'adopt_copy',o.source_attempt_id,
    p_escrow_id,p_version,p_lease_token,binding,evidence,
    jsonb_build_object('escrowManifest',o.escrow_manifest,
      'destinations',proof_items),current_setting('role',true))
  ON CONFLICT DO NOTHING;
  SELECT * INTO row FROM creative_craft_physical_challenges
   WHERE user_id=p_user_id AND phase='adopt_copy' AND escrow_id=p_escrow_id
     AND target_version=p_version AND target_lease_token=p_lease_token
   ORDER BY issued_at DESC LIMIT 1;
  RETURN jsonb_build_object('challengeId',row.challenge_id::text,
    'receiptId',row.receipt_id::text,'phase',row.phase,
    'binding',row.binding,'evidence',row.evidence,'proof',row.verifier_proof);
END $$;

CREATE FUNCTION creative_craft_launcher_challenge_load(p_challenge_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE row record;
BEGIN
  PERFORM creative_craft_require_role('launcher_verifier');
  SELECT * INTO row FROM creative_craft_physical_challenges
   WHERE challenge_id=p_challenge_id
     AND phase IN ('reserve','prestart_forget','terminal_forget');
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('challengeId',row.challenge_id::text,
    'receiptId',row.receipt_id::text,'phase',row.phase,
    'binding',row.binding,'evidence',row.evidence,'proof',row.verifier_proof);
END $$;
CREATE FUNCTION creative_craft_storage_challenge_load(p_challenge_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE row record;
BEGIN
  PERFORM creative_craft_require_role('storage_verifier');
  SELECT * INTO row FROM creative_craft_physical_challenges
   WHERE challenge_id=p_challenge_id AND phase='adopt_copy';
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('challengeId',row.challenge_id::text,
    'receiptId',row.receipt_id::text,'phase',row.phase,
    'binding',row.binding,'evidence',row.evidence,'proof',row.verifier_proof);
END $$;

CREATE FUNCTION creative_craft_verify_challenge(
  p_challenge_id uuid,p_phase text,p_role_kind text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE challenge record; prior record; owner record; attempt_row record;
        reservation_row record; runtime_row record; ack_row record;
        escrow_row record; body jsonb; observed timestamptz;
        receipt_hash text; current_fence boolean:=false;
BEGIN
  PERFORM creative_craft_require_role(p_role_kind);
  SELECT * INTO challenge FROM creative_craft_physical_challenges
   WHERE challenge_id=p_challenge_id AND phase=p_phase;
  IF NOT FOUND THEN RETURN NULL; END IF;
  -- The physical probe and this persistence call are separate by design.
  -- Serialize persistence with every claim/release so a late probe cannot mint
  -- an unconsumed receipt for a lease or version that has already changed.
  PERFORM pg_advisory_xact_lock(
    creative_craft_account_advisory_key(challenge.user_id));
  SELECT deletion_requested_at INTO owner FROM users
   WHERE id=challenge.user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR (p_phase IN ('reserve','adopt_copy')
                    AND owner.deletion_requested_at IS NOT NULL)
  THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(
    creative_craft_attempt_advisory_key(challenge.attempt_id));
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=challenge.user_id AND id=challenge.attempt_id FOR KEY SHARE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO challenge FROM creative_craft_physical_challenges
   WHERE challenge_id=p_challenge_id AND phase=p_phase FOR KEY SHARE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF p_phase='reserve' THEN
    SELECT * INTO reservation_row FROM creative_craft_launcher_reservations
     WHERE user_id=challenge.user_id AND attempt_id=challenge.attempt_id
     FOR KEY SHARE;
    current_fence:=reservation_row.attempt_id IS NOT NULL
      AND attempt_row.status='running'
      AND attempt_row.lease_token=attempt_row.claim_lease_token
      AND attempt_row.lease_until>clock_timestamp()
      AND attempt_row.provider_started_at IS NULL
      AND attempt_row.provider_returned_at IS NULL
      AND reservation_row.compensation_status='pending';
  ELSIF p_phase='prestart_forget' THEN
    SELECT * INTO reservation_row FROM creative_craft_launcher_reservations
     WHERE user_id=challenge.user_id AND attempt_id=challenge.attempt_id
     FOR KEY SHARE;
    current_fence:=reservation_row.attempt_id IS NOT NULL
      AND attempt_row.provider_started_at IS NULL
      AND attempt_row.provider_returned_at IS NULL
      AND reservation_row.compensation_status='running'
      AND reservation_row.compensation_lease_token=
          challenge.target_lease_token
      AND reservation_row.compensation_lease_until>clock_timestamp();
  ELSIF p_phase='terminal_forget' THEN
    SELECT * INTO reservation_row FROM creative_craft_launcher_reservations
     WHERE user_id=challenge.user_id AND attempt_id=challenge.attempt_id
     FOR KEY SHARE;
    SELECT * INTO runtime_row FROM creative_runtime_reconciliation_outbox
     WHERE user_id=challenge.user_id AND attempt_id=challenge.attempt_id
     FOR KEY SHARE;
    SELECT * INTO ack_row FROM creative_craft_launcher_ack_outbox
     WHERE user_id=challenge.user_id
       AND source_attempt_id=challenge.attempt_id FOR KEY SHARE;
    current_fence:=reservation_row.attempt_id IS NOT NULL
      AND reservation_row.reserved_at IS NOT NULL
      AND attempt_row.status IN ('succeeded','failed','cancelled')
      AND runtime_row.status='running'
      AND runtime_row.lease_token=challenge.target_lease_token
      AND runtime_row.lease_until>clock_timestamp()
      AND ack_row.status='running'
      AND ack_row.lease_token=challenge.target_lease_token
      AND ack_row.lease_until>clock_timestamp()
      AND runtime_row.terminal_status=attempt_row.status
      AND ack_row.terminal_status=attempt_row.status;
  ELSE
    SELECT * INTO escrow_row FROM creative_craft_output_adoption_outbox
     WHERE user_id=challenge.user_id AND escrow_id=challenge.escrow_id
     FOR KEY SHARE;
    current_fence:=escrow_row.escrow_id IS NOT NULL
      AND escrow_row.source_attempt_id=challenge.attempt_id
      AND escrow_row.state='adopting'
      AND escrow_row.version=challenge.target_version
      AND escrow_row.lease_token=challenge.target_lease_token
      AND escrow_row.lease_until>clock_timestamp();
  END IF;
  IF NOT COALESCE(current_fence,false) THEN RETURN NULL; END IF;
  -- A concurrent verifier may have won while this one waited for the fence.
  SELECT * INTO prior FROM creative_craft_physical_receipts
   WHERE user_id=challenge.user_id AND challenge_id=challenge.challenge_id;
  IF FOUND THEN
    RETURN jsonb_build_object('body',prior.body,
      'receiptSha256',prior.receipt_sha256,
      'observedAt',to_char(prior.observed_at AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
  END IF;
  body:=jsonb_build_object('schemaVersion',2,
    'receiptId',challenge.receipt_id::text,
    'challengeId',challenge.challenge_id::text,'phase',challenge.phase,
    'binding',challenge.binding,'evidence',challenge.evidence);
  receipt_hash:=creative_craft_json_sha256(body); observed:=clock_timestamp();
  INSERT INTO creative_craft_physical_receipts(
    user_id,receipt_id,challenge_id,installation_id,phase,body,
    receipt_sha256,observed_at,verifier_role)
  VALUES(challenge.user_id,challenge.receipt_id,challenge.challenge_id,
    challenge.installation_id,challenge.phase,body,receipt_hash,observed,
    current_setting('role',true))
  ON CONFLICT DO NOTHING;
  SELECT * INTO prior FROM creative_craft_physical_receipts
   WHERE user_id=challenge.user_id AND challenge_id=challenge.challenge_id;
  RETURN jsonb_build_object('body',prior.body,
    'receiptSha256',prior.receipt_sha256,
    'observedAt',to_char(prior.observed_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
END $$;

CREATE FUNCTION creative_craft_verify_reserve(p_challenge_id uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT creative_craft_verify_challenge($1,'reserve','launcher_verifier')
$$;
CREATE FUNCTION creative_craft_verify_prestart_forget(p_challenge_id uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT creative_craft_verify_challenge($1,'prestart_forget','launcher_verifier')
$$;
CREATE FUNCTION creative_craft_verify_terminal_forget(p_challenge_id uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT creative_craft_verify_challenge($1,'terminal_forget','launcher_verifier')
$$;
CREATE FUNCTION creative_craft_verify_adopt_copy(p_challenge_id uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT creative_craft_verify_challenge($1,'adopt_copy','storage_verifier')
$$;

CREATE FUNCTION creative_craft_complete_reservation(
  p_user_id uuid,p_attempt_id uuid,p_receipt_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; j record; s record; a record; r record; proof record;
        legacy jsonb; legacy_sha text;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT job_row.* INTO j FROM creative_execution_jobs job_row
  JOIN creative_execution_attempts attempt_row
    ON attempt_row.user_id=job_row.user_id AND attempt_row.job_id=job_row.id
   WHERE attempt_row.user_id=p_user_id AND attempt_row.id=p_attempt_id
   FOR UPDATE OF job_row;
  SELECT step_row.* INTO s FROM creative_execution_steps step_row
  JOIN creative_execution_attempts attempt_row
    ON attempt_row.user_id=step_row.user_id
   AND attempt_row.job_id=step_row.job_id
   AND attempt_row.step_id=step_row.step_id
   WHERE attempt_row.user_id=p_user_id AND attempt_row.id=p_attempt_id
   FOR UPDATE OF step_row;
  SELECT * INTO a FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO r FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT receipt.*,challenge.binding,challenge.evidence INTO proof
    FROM creative_craft_physical_receipts receipt
    JOIN creative_craft_physical_challenges challenge
      ON challenge.user_id=receipt.user_id
     AND challenge.challenge_id=receipt.challenge_id
   WHERE receipt.user_id=p_user_id AND receipt.receipt_id=p_receipt_id
     AND receipt.phase='reserve' AND challenge.attempt_id=p_attempt_id
   FOR KEY SHARE OF receipt,challenge;
  IF j.id IS NULL OR s.step_id IS NULL OR a.id IS NULL OR r.attempt_id IS NULL
     OR proof.receipt_id IS NULL
     OR r.job_id<>a.job_id OR r.step_id<>a.step_id
     OR r.attempt_no<>a.attempt_no
     OR r.claim_lease_token<>a.claim_lease_token
     OR r.fence_epoch<>a.fence_epoch OR r.admission_id<>a.admission_id
     OR r.admission_sha256<>a.admission_sha256
     OR r.claim_set_sha256<>a.claim_set_sha256
     OR proof.binding->>'ownerUserId'<>p_user_id::text
     OR (proof.binding->>'jobId')::uuid<>a.job_id
     OR (proof.binding->>'stepId')::uuid<>a.step_id
     OR (proof.binding->>'attemptId')::uuid<>a.id
     OR (proof.binding->>'attemptNo')::integer<>a.attempt_no
     OR proof.binding->>'claimLeaseTokenSha256'<>
        creative_craft_text_sha256(a.claim_lease_token::text)
     OR (proof.binding->>'fenceEpoch')::bigint<>r.fence_epoch
     OR proof.binding->>'admissionSha256'<>r.admission_sha256
     OR proof.binding->>'claimSetSha256'<>r.claim_set_sha256
     OR (proof.binding->>'dispatchId')::uuid<>r.dispatch_id
     OR proof.binding->>'requestSha256'<>r.request_sha256
     OR proof.binding->>'authoritySha256'<>r.authority_sha256
     OR proof.evidence->>'materializationSha256'<>
        creative_craft_json_sha256(jsonb_build_object(
          'inputRoot',r.input_root,'outputRoot',r.output_root,
          'inputs',r.inputs,'expectedOutputs',r.expected_outputs,
          'limits',r.limits))
     OR proof.evidence->>'inputTreeSha256'<>creative_craft_json_sha256(r.inputs)
     OR proof.evidence->>'outputTreeSha256'<>
        creative_craft_json_sha256(r.expected_outputs)
     OR proof.evidence->>'ownershipMarkerSha256'<>
        creative_craft_json_sha256(jsonb_build_object(
          'ownerUserId',p_user_id::text,'attemptId',p_attempt_id::text,
          'inputRoot',r.input_root,'outputRoot',r.output_root))
     OR (proof.evidence->>'inputCount')::integer<>jsonb_array_length(r.inputs)
     OR (proof.evidence->>'expectedOutputCount')::integer<>
        jsonb_array_length(r.expected_outputs) THEN RETURN NULL; END IF;
  legacy:=jsonb_build_object('schemaVersion',1,'dispatchId',r.dispatch_id::text,
    'requestSha256',r.request_sha256,'status','reserved',
    'authoritySha256',r.authority_sha256,'profileSha256',r.profile_sha256);
  legacy_sha:=creative_craft_json_sha256(legacy);
  IF r.reserved_at IS NOT NULL THEN
    IF r.reservation_receipt=legacy AND r.reservation_receipt_sha256=legacy_sha
       AND EXISTS (SELECT 1 FROM creative_craft_physical_receipt_consumptions
        WHERE user_id=p_user_id AND receipt_id=p_receipt_id
          AND completion_kind='reservation') THEN RETURN legacy; END IF;
    RETURN NULL;
  END IF;
  IF u.deletion_requested_at IS NOT NULL OR j.status<>'running'
     OR s.status<>'running' OR s.kind<>'craft' OR NOT s.provider_call
     OR a.status<>'running'
     OR j.lease_token<>a.claim_lease_token
     OR s.lease_token<>a.claim_lease_token
     OR a.lease_token<>a.claim_lease_token
     OR j.lease_until<=clock_timestamp()
     OR s.lease_until<=clock_timestamp()
     OR a.lease_until<=clock_timestamp()
     OR a.provider_started_at IS NOT NULL
     OR a.provider_returned_at IS NOT NULL THEN
    INSERT INTO creative_craft_physical_receipt_consumptions(
      user_id,receipt_id,completion_kind,attempt_id)
    VALUES(p_user_id,p_receipt_id,'reservation_rejected',p_attempt_id)
    ON CONFLICT DO NOTHING;
    RETURN NULL;
  END IF;
  UPDATE creative_craft_launcher_reservations SET
    reservation_receipt=legacy,reservation_receipt_sha256=legacy_sha,
    reserved_at=clock_timestamp(),compensation_status='confirmed',
    updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id
     AND reserved_at IS NULL AND compensation_status='pending';
  IF NOT FOUND THEN RETURN NULL; END IF;
  INSERT INTO creative_craft_physical_receipt_consumptions(
    user_id,receipt_id,completion_kind,attempt_id)
  VALUES(p_user_id,p_receipt_id,'reservation',p_attempt_id);
  RETURN legacy;
END $$;

CREATE FUNCTION creative_craft_complete_compensation(
  p_user_id uuid,p_attempt_id uuid,p_lease_token uuid,p_receipt_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; a record; r record; proof record; legacy jsonb; legacy_sha text;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO a FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO r FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT receipt.*,challenge.binding,challenge.evidence INTO proof
    FROM creative_craft_physical_receipts receipt
    JOIN creative_craft_physical_challenges challenge USING(user_id,challenge_id)
   WHERE receipt.user_id=p_user_id AND receipt.receipt_id=p_receipt_id
     AND receipt.phase='prestart_forget' AND challenge.attempt_id=p_attempt_id
     AND challenge.target_lease_token=p_lease_token
   FOR KEY SHARE OF receipt,challenge;
  IF a.id IS NULL OR r.attempt_id IS NULL OR proof.receipt_id IS NULL
     OR proof.binding->>'ownerUserId' IS DISTINCT FROM p_user_id::text
     OR (proof.binding->>'attemptId')::uuid IS DISTINCT FROM a.id
     OR (proof.binding->>'jobId')::uuid IS DISTINCT FROM a.job_id
     OR (proof.binding->>'stepId')::uuid IS DISTINCT FROM a.step_id
     OR (proof.binding->>'attemptNo')::integer IS DISTINCT FROM a.attempt_no
     OR proof.binding->>'claimLeaseTokenSha256' IS DISTINCT FROM
        creative_craft_text_sha256(a.claim_lease_token::text)
     OR (proof.binding->>'fenceEpoch')::bigint IS DISTINCT FROM a.fence_epoch
     OR proof.binding->>'admissionSha256' IS DISTINCT FROM a.admission_sha256
     OR proof.binding->>'claimSetSha256' IS DISTINCT FROM a.claim_set_sha256
     OR (proof.binding->>'dispatchId')::uuid IS DISTINCT FROM r.dispatch_id
     OR proof.binding->>'requestSha256' IS DISTINCT FROM r.request_sha256
     OR proof.binding->>'authoritySha256' IS DISTINCT FROM r.authority_sha256
     OR proof.evidence->>'tombstoneSha256' IS DISTINCT FROM
        creative_craft_json_sha256(jsonb_build_object(
          'schemaVersion',2,'phase','prestart_forget',
          'dispatchId',r.dispatch_id::text,'requestSha256',r.request_sha256,
          'leaseToken',p_lease_token::text)) THEN RETURN NULL; END IF;
  legacy:=jsonb_build_object('schemaVersion',1,'dispatchId',r.dispatch_id::text,
    'requestSha256',r.request_sha256,'status','forgotten',
    'cleanup','verified','tombstoneSha256',proof.evidence->>'tombstoneSha256');
  legacy_sha:=creative_craft_json_sha256(legacy);
  IF r.compensation_status='compensated' THEN
    IF r.compensation_receipt=legacy
       AND r.compensation_receipt_sha256=legacy_sha
       AND EXISTS (SELECT 1 FROM creative_craft_physical_receipt_consumptions
        WHERE user_id=p_user_id AND receipt_id=p_receipt_id
          AND completion_kind='compensation') THEN RETURN legacy_sha; END IF;
    RETURN NULL;
  END IF;
  IF a.provider_started_at IS NOT NULL OR a.provider_returned_at IS NOT NULL
     OR r.compensation_status<>'running'
     OR r.compensation_lease_token<>p_lease_token
     OR r.compensation_lease_until<=clock_timestamp() THEN
    INSERT INTO creative_craft_physical_receipt_consumptions(
      user_id,receipt_id,completion_kind,attempt_id)
    VALUES(p_user_id,p_receipt_id,'compensation_rejected',p_attempt_id)
    ON CONFLICT DO NOTHING;
    RETURN NULL;
  END IF;
  UPDATE creative_craft_launcher_reservations SET
    compensation_status='compensated',compensation_lease_token=NULL,
    compensation_lease_until=NULL,compensation_receipt=legacy,
    compensation_receipt_sha256=legacy_sha,compensated_at=clock_timestamp(),
    compensation_last_error=NULL,updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id
     AND compensation_status='running' AND compensation_lease_token=p_lease_token
     AND compensation_lease_until>clock_timestamp();
  IF NOT FOUND THEN RETURN NULL; END IF;
  INSERT INTO creative_craft_physical_receipt_consumptions(
    user_id,receipt_id,completion_kind,attempt_id)
  VALUES(p_user_id,p_receipt_id,'compensation',p_attempt_id);
  -- A reserve probe may have persisted immediately before this recovery won.
  -- The verified forget closes that same physical namespace, so consume every
  -- still-unapplied reserve proof in this transaction as rejected evidence.
  INSERT INTO creative_craft_physical_receipt_consumptions(
    user_id,receipt_id,completion_kind,attempt_id)
  SELECT receipt.user_id,receipt.receipt_id,'reservation_rejected',p_attempt_id
    FROM creative_craft_physical_receipts receipt
    JOIN creative_craft_physical_challenges challenge
      ON challenge.user_id=receipt.user_id
     AND challenge.challenge_id=receipt.challenge_id
   WHERE receipt.user_id=p_user_id AND receipt.phase='reserve'
     AND challenge.attempt_id=p_attempt_id
     AND NOT EXISTS (
       SELECT 1 FROM creative_craft_physical_receipt_consumptions consumed
        WHERE consumed.user_id=receipt.user_id
          AND consumed.receipt_id=receipt.receipt_id)
  ON CONFLICT DO NOTHING;
  RETURN legacy_sha;
END $$;

CREATE FUNCTION creative_craft_complete_ack(
  p_user_id uuid,p_attempt_id uuid,p_runtime_lease_token uuid,p_receipt_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; a record; r record; runtime record; ack record; proof record;
        completed timestamptz;
BEGIN
  PERFORM creative_craft_require_role('ack');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO a FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO r FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT * INTO runtime FROM creative_runtime_reconciliation_outbox
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT * INTO ack FROM creative_craft_launcher_ack_outbox
   WHERE user_id=p_user_id AND source_attempt_id=p_attempt_id FOR UPDATE;
  SELECT receipt.*,challenge.binding,challenge.evidence INTO proof
    FROM creative_craft_physical_receipts receipt
    JOIN creative_craft_physical_challenges challenge USING(user_id,challenge_id)
   WHERE receipt.user_id=p_user_id AND receipt.receipt_id=p_receipt_id
     AND receipt.phase='terminal_forget' AND challenge.attempt_id=p_attempt_id
     AND challenge.target_lease_token=p_runtime_lease_token
   FOR KEY SHARE OF receipt,challenge;
  IF a.id IS NULL OR r.attempt_id IS NULL OR proof.receipt_id IS NULL
     OR proof.binding->>'ownerUserId' IS DISTINCT FROM p_user_id::text
     OR (proof.binding->>'attemptId')::uuid IS DISTINCT FROM a.id
     OR (proof.binding->>'jobId')::uuid IS DISTINCT FROM a.job_id
     OR (proof.binding->>'stepId')::uuid IS DISTINCT FROM a.step_id
     OR (proof.binding->>'attemptNo')::integer IS DISTINCT FROM a.attempt_no
     OR (proof.binding->>'fenceEpoch')::bigint IS DISTINCT FROM a.fence_epoch
     OR (proof.binding->>'dispatchId')::uuid IS DISTINCT FROM r.dispatch_id
     OR proof.binding->>'requestSha256' IS DISTINCT FROM r.request_sha256
     OR proof.binding->>'authoritySha256' IS DISTINCT FROM r.authority_sha256
     OR proof.evidence->>'terminalReceiptSha256' IS DISTINCT FROM
        ack.terminal_receipt_sha256 THEN RETURN false; END IF;
  IF runtime.status='done' AND ack.status='done'
     AND EXISTS (SELECT 1 FROM creative_craft_physical_receipt_consumptions
       WHERE user_id=p_user_id AND receipt_id=p_receipt_id
         AND completion_kind='ack') THEN RETURN true; END IF;
  IF runtime.status<>'running'
     OR runtime.lease_token<>p_runtime_lease_token
     OR runtime.lease_until<=clock_timestamp() OR ack.status<>'running'
     OR ack.lease_token<>p_runtime_lease_token OR ack.lease_until<=clock_timestamp()
     OR runtime.terminal_status<>a.status OR ack.terminal_status<>a.status THEN
    INSERT INTO creative_craft_physical_receipt_consumptions(
      user_id,receipt_id,completion_kind,attempt_id)
    VALUES(p_user_id,p_receipt_id,'ack_rejected',p_attempt_id)
    ON CONFLICT DO NOTHING;
    RETURN false;
  END IF;
  completed:=clock_timestamp();
  UPDATE creative_craft_launcher_ack_outbox SET status='done',lease_token=NULL,
    lease_until=NULL,last_error=NULL,completed_at=completed,updated_at=completed
   WHERE user_id=p_user_id AND source_attempt_id=p_attempt_id
     AND status='running' AND lease_token=p_runtime_lease_token;
  UPDATE creative_runtime_reconciliation_outbox SET status='done',lease_token=NULL,
    lease_until=NULL,last_error=NULL,completed_at=completed,updated_at=completed
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id
     AND status='running' AND lease_token=p_runtime_lease_token;
  IF NOT FOUND THEN RAISE EXCEPTION 'runtime ACK CAS lost' USING ERRCODE='40001'; END IF;
  INSERT INTO creative_craft_physical_receipt_consumptions(
    user_id,receipt_id,completion_kind,attempt_id)
  VALUES(p_user_id,p_receipt_id,'ack',p_attempt_id);
  RETURN true;
END $$;

CREATE FUNCTION creative_craft_complete_adoption(
  p_user_id uuid,p_escrow_id uuid,p_version integer,p_lease_token uuid,
  p_receipt_id uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; o record; proof record; result_sha text; adoption_items jsonb;
BEGIN
  PERFORM creative_craft_require_role('escrow');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO o FROM creative_craft_output_adoption_outbox
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(o.source_attempt_id));
  PERFORM 1 FROM creative_execution_attempts WHERE user_id=p_user_id
    AND id=o.source_attempt_id FOR UPDATE;
  SELECT * INTO o FROM creative_craft_output_adoption_outbox
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id FOR UPDATE;
  SELECT receipt.*,challenge.evidence,challenge.verifier_proof INTO proof
    FROM creative_craft_physical_receipts receipt
    JOIN creative_craft_physical_challenges challenge USING(user_id,challenge_id)
   WHERE receipt.user_id=p_user_id AND receipt.receipt_id=p_receipt_id
     AND receipt.phase='adopt_copy' AND challenge.escrow_id=p_escrow_id
     AND challenge.target_version=p_version
     AND challenge.target_lease_token=p_lease_token
   FOR KEY SHARE OF receipt,challenge;
  IF proof.receipt_id IS NULL
     OR proof.evidence->>'manifestSha256' IS DISTINCT FROM o.escrow_manifest_sha256
     OR (proof.evidence->>'candidateId')::uuid IS DISTINCT FROM o.candidate_id
     OR proof.evidence->>'artifactManifestSha256' IS DISTINCT FROM
        o.artifact_manifest_sha256 THEN RETURN NULL; END IF;
  IF o.adoption_manifest_sha256 IS NOT NULL
     AND EXISTS (SELECT 1 FROM creative_craft_physical_receipt_consumptions
       WHERE user_id=p_user_id AND receipt_id=p_receipt_id
         AND completion_kind='adoption') THEN
    RETURN o.adoption_manifest_sha256;
  END IF;
  IF o.state<>'adopting' OR o.version<>p_version
     OR o.lease_token<>p_lease_token OR o.lease_until<=clock_timestamp() THEN
    INSERT INTO creative_craft_physical_receipt_consumptions(
      user_id,receipt_id,completion_kind,attempt_id,escrow_id,target_version)
    VALUES(p_user_id,p_receipt_id,'adoption_rejected',o.source_attempt_id,
      p_escrow_id,p_version)
    ON CONFLICT DO NOTHING;
    RETURN NULL;
  END IF;
  SELECT jsonb_agg(jsonb_build_object('artifact',manifest.value,
      'storageReceipt',destination.value->'storageReceipt')
      ORDER BY manifest.ordinality) INTO adoption_items
    FROM jsonb_array_elements(o.escrow_manifest->'artifacts')
           WITH ORDINALITY manifest(value,ordinality)
    JOIN jsonb_array_elements(proof.verifier_proof->'destinations')
           destination(value)
      ON (destination.value->>'ordinal')::integer=manifest.ordinality-1
   WHERE destination.value#>>'{storageReceipt,mimeType}'=
           manifest.value->>'mimeType'
     AND (destination.value#>>'{storageReceipt,byteSize}')::bigint=
           (manifest.value->>'byteSize')::bigint
     AND destination.value#>>'{storageReceipt,sha256}'=manifest.value->>'sha256';
  IF adoption_items IS NULL OR jsonb_array_length(adoption_items)<>
       jsonb_array_length(o.escrow_manifest->'artifacts') THEN RETURN NULL; END IF;
  result_sha:=creative_craft_json_sha256(jsonb_build_object('schemaVersion',1,
    'escrowId',p_escrow_id::text,'manifestSha256',o.escrow_manifest_sha256,
    'items',adoption_items));
  UPDATE creative_craft_output_adoption_outbox SET state='adopted',version=version+1,
    lease_token=NULL,lease_until=NULL,
    quarantine_set_sha256=proof.evidence->>'quarantineSetSha256',
    adoption_manifest_sha256=result_sha,
    adoption_attempt_id=(proof.evidence->>'adoptionAttemptId')::uuid,
    adoption_fence_epoch=(proof.evidence->>'adoptionFenceEpoch')::bigint,
    adoption_result_sha256=proof.evidence->>'adoptionResultSha256',
    adopted_at=clock_timestamp(),updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id AND state='adopting'
     AND version=p_version AND lease_token=p_lease_token
     AND lease_until>clock_timestamp();
  IF NOT FOUND THEN RETURN NULL; END IF;
  INSERT INTO creative_craft_physical_receipt_consumptions(
    user_id,receipt_id,completion_kind,attempt_id,escrow_id,target_version)
  VALUES(p_user_id,p_receipt_id,'adoption',o.source_attempt_id,p_escrow_id,p_version);
  RETURN result_sha;
END $$;

CREATE FUNCTION creative_craft_complete_cleanup(
  p_user_id uuid,p_escrow_id uuid,p_version integer,p_lease_token uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; o record; ack record; physical record; legacy jsonb; legacy_sha text;
BEGIN
  PERFORM creative_craft_require_role('escrow');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO o FROM creative_craft_output_adoption_outbox
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(o.source_attempt_id));
  PERFORM 1 FROM creative_execution_attempts WHERE user_id=p_user_id
    AND id=o.source_attempt_id FOR UPDATE;
  PERFORM 1 FROM creative_craft_launcher_reservations WHERE user_id=p_user_id
    AND attempt_id=o.source_attempt_id FOR UPDATE;
  PERFORM 1 FROM creative_runtime_reconciliation_outbox WHERE user_id=p_user_id
    AND attempt_id=o.source_attempt_id FOR UPDATE;
  SELECT * INTO ack FROM creative_craft_launcher_ack_outbox
   WHERE user_id=p_user_id AND source_attempt_id=o.source_attempt_id FOR UPDATE;
  SELECT * INTO o FROM creative_craft_output_adoption_outbox
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id FOR UPDATE;
  SELECT receipt.receipt_id INTO physical
    FROM creative_craft_physical_receipts receipt
    JOIN creative_craft_physical_receipt_consumptions consumed
      ON consumed.user_id=receipt.user_id AND consumed.receipt_id=receipt.receipt_id
     AND consumed.completion_kind='ack'
   WHERE consumed.user_id=p_user_id AND consumed.attempt_id=o.source_attempt_id
     AND receipt.phase='terminal_forget' FOR KEY SHARE OF receipt,consumed;
  IF o.state<>'reconciling_cleanup' OR o.version<>p_version
     OR o.lease_token<>p_lease_token OR o.lease_until<=clock_timestamp()
     OR ack.status<>'done' OR physical.receipt_id IS NULL THEN RETURN NULL; END IF;
  legacy:=jsonb_build_object('schemaVersion',1,'escrowId',o.escrow_id::text,
    'manifestSha256',o.escrow_manifest_sha256,'status','launcher_forgotten',
    'launcherAck',jsonb_build_object('sourceAttemptId',ack.source_attempt_id::text,
      'dispatchId',ack.dispatch_id::text,'requestSha256',ack.request_sha256,
      'authoritySha256',ack.authority_sha256,
      'terminalReceiptSha256',ack.terminal_receipt_sha256));
  legacy_sha:=creative_craft_json_sha256(legacy);
  UPDATE creative_craft_output_adoption_outbox SET state='deleted',version=version+1,
    lease_token=NULL,lease_until=NULL,cleanup_receipt=legacy,
    cleanup_receipt_sha256=legacy_sha,completed_at=clock_timestamp(),
    updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id
     AND state='reconciling_cleanup' AND version=p_version
     AND lease_token=p_lease_token AND lease_until>clock_timestamp();
  IF NOT FOUND THEN RETURN NULL; END IF;
  INSERT INTO creative_craft_physical_receipt_consumptions(
    user_id,receipt_id,completion_kind,attempt_id,escrow_id,target_version)
  VALUES(p_user_id,physical.receipt_id,'cleanup',o.source_attempt_id,
    p_escrow_id,p_version);
  RETURN legacy_sha;
END $$;

CREATE FUNCTION creative_craft_preparer_append_reservation(
  p_user_id uuid,p_attempt_id uuid,p_materialization jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; j record; s record; a record; request_body jsonb;
        request_hash text; authority_body jsonb; authority_hash text;
        profile_hash text; inserted integer; stored record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  IF jsonb_typeof(p_materialization)<>'object'
     OR (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(p_materialization) key)
        <> ARRAY['controlDocument','dispatchId','expectedOutputs','inputRoot',
                 'inputs','limits','outputRoot','profile']::text[]
     OR jsonb_typeof(p_materialization->'profile')<>'object'
     OR jsonb_typeof(p_materialization->'controlDocument')<>'object'
     OR jsonb_typeof(p_materialization->'inputs')<>'array'
     OR jsonb_typeof(p_materialization->'expectedOutputs')<>'array'
     OR jsonb_typeof(p_materialization->'limits')<>'object'
  THEN RAISE EXCEPTION 'materialization DTO is not closed' USING ERRCODE='22023'; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR u.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO a FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO j FROM creative_execution_jobs
   WHERE user_id=p_user_id AND id=a.job_id FOR UPDATE;
  SELECT * INTO s FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=a.job_id AND step_id=a.step_id FOR UPDATE;
  SELECT * INTO a FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  IF j.status<>'running' OR s.status<>'running' OR a.status<>'running'
     OR s.kind<>'craft' OR NOT s.provider_call
     OR a.provider_started_at IS NOT NULL OR a.provider_returned_at IS NOT NULL
     OR a.craft_authority_bound_at IS NULL THEN RETURN NULL; END IF;
  request_body:=jsonb_build_object('schemaVersion',2,
    'dispatchId',p_materialization->>'dispatchId',
    'attempt',jsonb_build_object('ownerUserId',p_user_id::text,
      'jobId',a.job_id::text,'stepId',a.step_id::text,'attemptId',a.id::text,
      'attemptNo',a.attempt_no,'claimLeaseToken',a.claim_lease_token::text,
      'fenceEpoch',a.fence_epoch,'admissionSha256',a.admission_sha256,
      'claimSetSha256',a.claim_set_sha256),
    'authority',jsonb_build_object(
      'jobBindingSha256',a.craft_job_binding_sha256,
      'preflightSha256',a.craft_preflight_sha256,
      'adapterPlanSha256',a.craft_adapter_plan_sha256,
      'capabilityMatrixSha256',a.craft_capability_matrix_sha256,
      'contractSchemaSha256',a.craft_contract_schema_sha256,
      'adapterCompilerVersion',a.craft_adapter_compiler_version,
      'adapterSourceSha256',a.craft_adapter_source_sha256,
      'recipeSha256',a.craft_recipe_sha256,
      'inputManifestSha256',a.craft_resolved_input_manifest_sha256));
  request_hash:=creative_craft_json_sha256(request_body);
  profile_hash:=creative_craft_json_sha256(p_materialization->'profile');
  authority_body:=jsonb_build_object('dispatchId',p_materialization->>'dispatchId',
    'requestSha256',request_hash,'ownerUserId',p_user_id::text,
    'attemptId',p_attempt_id::text,'requestAuthority',request_body->'authority',
    'profileId',p_materialization#>>'{profile,profileId}',
    'controlSha256',creative_craft_json_sha256(p_materialization->'controlDocument'),
    'inputRoot',p_materialization->>'inputRoot',
    'outputRoot',p_materialization->>'outputRoot',
    'inputs',p_materialization->'inputs',
    'expectedOutputs',p_materialization->'expectedOutputs',
    'limits',p_materialization->'limits');
  authority_hash:=creative_craft_json_sha256(authority_body);
  INSERT INTO creative_craft_launcher_reservations(
    user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,fence_epoch,
    admission_id,admission_sha256,claim_set_sha256,dispatch_id,request_sha256,
    request_authority,profile_id,profile_sha256,control_document,input_root,
    output_root,inputs,expected_outputs,limits,authority_sha256)
  VALUES(p_user_id,p_attempt_id,a.job_id,a.step_id,a.attempt_no,
    a.claim_lease_token,a.fence_epoch,a.admission_id,a.admission_sha256,
    a.claim_set_sha256,(p_materialization->>'dispatchId')::uuid,request_hash,
    request_body->'authority',p_materialization#>>'{profile,profileId}',profile_hash,
    p_materialization->'controlDocument',p_materialization->>'inputRoot',
    p_materialization->>'outputRoot',p_materialization->'inputs',
    p_materialization->'expectedOutputs',p_materialization->'limits',authority_hash)
  ON CONFLICT(user_id,attempt_id) DO NOTHING;
  GET DIAGNOSTICS inserted=ROW_COUNT;
  SELECT * INTO stored FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR SHARE;
  IF stored.request_sha256<>request_hash OR stored.authority_sha256<>authority_hash
     OR stored.profile_sha256<>profile_hash THEN
    RAISE EXCEPTION 'reservation append conflicts with durable authority'
      USING ERRCODE='40001';
  END IF;
  RETURN jsonb_build_object('created',inserted=1,'request',jsonb_build_object(
    'body',request_body,'requestSha256',request_hash),
    'authoritySha256',authority_hash,'profileSha256',profile_hash);
END $$;

CREATE FUNCTION creative_craft_recover_expired_prestart(
  p_user_id uuid,p_attempt_id uuid,p_max_claims integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; reservation_row record;
        reservation_present boolean:=false; outcome text; terminal text;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  IF p_max_claims<1 OR p_max_claims>10 THEN
    RAISE EXCEPTION 'invalid Craft recovery claim limit' USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
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
  SELECT * INTO reservation_row FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  reservation_present:=FOUND;
  IF job_row.id IS NULL OR step_row.step_id IS NULL OR attempt_row.id IS NULL
     OR job_row.status<>'running' OR step_row.status<>'running'
     OR attempt_row.status<>'running' OR step_row.kind<>'craft'
     OR NOT step_row.provider_call
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR step_row.provider_started_at IS NOT NULL
     OR step_row.provider_returned_at IS NOT NULL
     OR attempt_row.lease_until>clock_timestamp()
     OR step_row.lease_until>clock_timestamp()
     OR job_row.lease_until>clock_timestamp()
     OR step_row.lease_token IS DISTINCT FROM attempt_row.lease_token
     OR job_row.lease_token IS DISTINCT FROM attempt_row.lease_token
     OR (reservation_present AND
       (reservation_row.job_id,reservation_row.step_id,
        reservation_row.attempt_no,reservation_row.claim_lease_token,
        reservation_row.fence_epoch,reservation_row.admission_sha256,
        reservation_row.claim_set_sha256) IS DISTINCT FROM
       (attempt_row.job_id,attempt_row.step_id,attempt_row.attempt_no,
        attempt_row.claim_lease_token,attempt_row.fence_epoch,
        attempt_row.admission_sha256,attempt_row.claim_set_sha256))
  THEN RETURN NULL; END IF;
  -- Any durable launcher plan may already own its namespace even before the
  -- first byte or reserve proof is visible.  It cannot be reused by merely
  -- cancelling the SQL attempt.  Keep all execution rows running until its
  -- pre-start forget is durably consumed by complete_compensation.
  IF reservation_present
     AND reservation_row.compensation_status<>'compensated'
  THEN
    RETURN jsonb_build_object(
      'outcome','cleanup_required','terminalStatus','pending');
  END IF;
  INSERT INTO creative_craft_physical_receipt_consumptions(
    user_id,receipt_id,completion_kind,attempt_id)
  SELECT receipt.user_id,receipt.receipt_id,'reservation_rejected',
         challenge.attempt_id
    FROM creative_craft_physical_receipts receipt
    JOIN creative_craft_physical_challenges challenge
      ON challenge.user_id=receipt.user_id
     AND challenge.challenge_id=receipt.challenge_id
   WHERE receipt.user_id=p_user_id AND challenge.attempt_id=p_attempt_id
     AND receipt.phase='reserve'
     AND NOT EXISTS (
       SELECT 1 FROM creative_craft_physical_receipt_consumptions consumed
        WHERE consumed.user_id=receipt.user_id
          AND consumed.receipt_id=receipt.receipt_id)
  ON CONFLICT DO NOTHING;
  IF EXISTS (
    SELECT 1 FROM creative_craft_physical_receipts receipt
     WHERE receipt.user_id=p_user_id
       AND NOT EXISTS (
         SELECT 1 FROM creative_craft_physical_receipt_consumptions consumed
          WHERE consumed.user_id=receipt.user_id
            AND consumed.receipt_id=receipt.receipt_id)
       AND EXISTS (
         SELECT 1 FROM creative_craft_physical_challenges challenge
          WHERE challenge.user_id=receipt.user_id
            AND challenge.challenge_id=receipt.challenge_id
            AND challenge.attempt_id=p_attempt_id
            AND challenge.phase='reserve'))
  THEN RAISE EXCEPTION 'reserve receipt drain lost' USING ERRCODE='40001'; END IF;
  IF attempt_row.attempt_no>=p_max_claims THEN
    UPDATE creative_execution_attempts SET status='failed',
      error_code='claim_limit_reached',finished_at=clock_timestamp(),
      updated_at=clock_timestamp(),lease_token=NULL,lease_owner=NULL,
      lease_until=NULL WHERE user_id=p_user_id AND id=p_attempt_id
        AND status='running';
    UPDATE creative_execution_steps SET status='failed',
      error_code='claim_limit_reached',finished_at=clock_timestamp(),
      updated_at=clock_timestamp(),lease_token=NULL,lease_owner=NULL,
      lease_until=NULL WHERE user_id=p_user_id AND job_id=attempt_row.job_id
        AND step_id=attempt_row.step_id AND status='running';
    UPDATE creative_execution_steps SET status='cancelled',
      error_code='blocked_by_failed',finished_at=clock_timestamp(),
      updated_at=clock_timestamp() WHERE user_id=p_user_id
        AND job_id=attempt_row.job_id AND status IN ('held','queued');
    UPDATE creative_execution_jobs SET status='failed',
      error_code='claim_limit_reached',finished_at=clock_timestamp(),
      updated_at=clock_timestamp(),lease_token=NULL,lease_owner=NULL,
      lease_until=NULL WHERE user_id=p_user_id AND id=attempt_row.job_id
        AND status='running';
    outcome:='failed'; terminal:='failed';
  ELSE
    UPDATE creative_execution_attempts SET status='cancelled',
      error_code='pre_provider_interrupted',finished_at=clock_timestamp(),
      updated_at=clock_timestamp(),lease_token=NULL,lease_owner=NULL,
      lease_until=NULL WHERE user_id=p_user_id AND id=p_attempt_id
        AND status='running';
    UPDATE creative_execution_steps SET status='queued',error_code=NULL,
      updated_at=clock_timestamp(),lease_token=NULL,lease_owner=NULL,
      lease_until=NULL WHERE user_id=p_user_id AND job_id=attempt_row.job_id
        AND step_id=attempt_row.step_id AND status='running';
    UPDATE creative_execution_jobs SET status='queued',error_code=NULL,
      available_at=clock_timestamp(),updated_at=clock_timestamp(),
      lease_token=NULL,lease_owner=NULL,lease_until=NULL
      WHERE user_id=p_user_id AND id=attempt_row.job_id AND status='running';
    outcome:='queued'; terminal:='cancelled';
  END IF;
  RETURN jsonb_build_object('outcome',outcome,'terminalStatus',terminal);
END $$;

CREATE OR REPLACE FUNCTION creative_craft_preparer_release_compensation(
  p_user_id uuid,p_attempt_id uuid,p_lease_token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; seed record; job_row record; step_row record;
        attempt_row record; reservation_row record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT job_id,step_id INTO seed FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT * INTO job_row FROM creative_execution_jobs
   WHERE user_id=p_user_id AND id=seed.job_id FOR UPDATE;
  SELECT * INTO step_row FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=seed.job_id AND step_id=seed.step_id
   FOR UPDATE;
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO reservation_row FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  IF job_row.id IS NULL OR step_row.step_id IS NULL OR attempt_row.id IS NULL
     OR reservation_row.attempt_id IS NULL OR step_row.kind<>'craft'
     OR NOT step_row.provider_call
     OR (reservation_row.job_id,reservation_row.step_id,
         reservation_row.attempt_no,reservation_row.claim_lease_token,
         reservation_row.fence_epoch,reservation_row.admission_sha256,
         reservation_row.claim_set_sha256) IS DISTINCT FROM
        (attempt_row.job_id,attempt_row.step_id,attempt_row.attempt_no,
         attempt_row.claim_lease_token,attempt_row.fence_epoch,
         attempt_row.admission_sha256,attempt_row.claim_set_sha256)
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR reservation_row.compensation_status<>'running'
     OR reservation_row.compensation_lease_token<>p_lease_token
     THEN RETURN false; END IF;
  UPDATE creative_craft_launcher_reservations
     SET compensation_lease_until=clock_timestamp(),
         compensation_last_error='transition_failed',
         updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id
     AND compensation_status='running'
     AND compensation_lease_token=p_lease_token;
  RETURN FOUND;
END $$;

CREATE FUNCTION creative_craft_runtime_enqueue(
  p_user_id uuid,p_attempt_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; j record; s record; a record; present record;
BEGIN
  PERFORM creative_craft_require_role('ack');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO a FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT * INTO j FROM creative_execution_jobs WHERE user_id=p_user_id
    AND id=a.job_id FOR UPDATE;
  SELECT * INTO s FROM creative_execution_steps WHERE user_id=p_user_id
    AND job_id=a.job_id AND step_id=a.step_id FOR UPDATE;
  SELECT * INTO a FROM creative_execution_attempts WHERE user_id=p_user_id
    AND id=p_attempt_id FOR UPDATE;
  IF s.kind<>'craft' OR NOT s.provider_call
     OR a.status NOT IN ('succeeded','failed','cancelled')
     OR a.provider_returned_at IS NULL THEN RETURN false; END IF;
  INSERT INTO creative_runtime_reconciliation_outbox(
    user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,fence_epoch,
    admission_sha256,claim_set_sha256,kind,provider_call,terminal_status)
  VALUES(p_user_id,p_attempt_id,a.job_id,a.step_id,a.attempt_no,
    a.claim_lease_token,a.fence_epoch,a.admission_sha256,a.claim_set_sha256,
    'craft',true,a.status)
  ON CONFLICT(user_id,attempt_id) DO NOTHING;
  SELECT * INTO present FROM creative_runtime_reconciliation_outbox
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR SHARE;
  RETURN present.kind='craft' AND present.provider_call
    AND present.terminal_status=a.status AND present.job_id=a.job_id
    AND present.step_id=a.step_id AND present.attempt_no=a.attempt_no
    AND present.claim_lease_token=a.claim_lease_token
    AND present.fence_epoch=a.fence_epoch;
END $$;

DROP FUNCTION creative_craft_ack_claim(uuid,uuid,uuid);
CREATE FUNCTION creative_craft_ack_claim(p_user_id uuid,p_attempt_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; a record; r record; runtime record; ack record; adoption record;
        token uuid:=gen_random_uuid(); terminal_sha text;
BEGIN
  PERFORM creative_craft_require_role('ack');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO a FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO r FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT * INTO runtime FROM creative_runtime_reconciliation_outbox
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  IF a.status NOT IN ('succeeded','failed','cancelled') OR r.reserved_at IS NULL
     OR runtime.terminal_status<>a.status OR runtime.kind<>'craft'
     OR NOT runtime.provider_call OR runtime.status='done' THEN RETURN NULL; END IF;
  IF a.status='succeeded' THEN
    SELECT * INTO adoption FROM creative_craft_output_adoption_outbox
     WHERE user_id=p_user_id AND source_attempt_id=p_attempt_id FOR UPDATE;
    IF adoption.state NOT IN ('adopted','reconciliation_pending',
      'reconciling_cleanup','deleted') THEN RETURN NULL; END IF;
  ELSE
    SELECT NULL::uuid AS candidate_id,NULL::text AS quarantine_set_sha256,
           NULL::uuid AS adoption_attempt_id,
           NULL::bigint AS adoption_fence_epoch,
           NULL::text AS adoption_result_sha256 INTO adoption;
  END IF;
  terminal_sha:=creative_craft_json_sha256(jsonb_build_object('schemaVersion',1,
    'dispatchId',r.dispatch_id::text,'requestSha256',r.request_sha256,
    'terminalStatus',a.status,'attemptResultSha256',a.result_sha256));
  INSERT INTO creative_craft_launcher_ack_outbox(
    user_id,source_attempt_id,job_id,source_step_id,attempt_no,
    claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,
    terminal_status,dispatch_id,request_sha256,authority_sha256,
    terminal_receipt_sha256,candidate_id,quarantine_set_sha256,
    adoption_attempt_id,adoption_fence_epoch,adoption_result_sha256)
  VALUES(p_user_id,p_attempt_id,a.job_id,a.step_id,a.attempt_no,
    a.claim_lease_token,a.fence_epoch,a.admission_sha256,a.claim_set_sha256,
    a.status,r.dispatch_id,r.request_sha256,r.authority_sha256,terminal_sha,
    adoption.candidate_id,adoption.quarantine_set_sha256,
    adoption.adoption_attempt_id,adoption.adoption_fence_epoch,
    adoption.adoption_result_sha256)
  ON CONFLICT(user_id,source_attempt_id) DO NOTHING;
  SELECT * INTO ack FROM creative_craft_launcher_ack_outbox
   WHERE user_id=p_user_id AND source_attempt_id=p_attempt_id FOR UPDATE;
  IF ack.terminal_status<>a.status OR ack.terminal_receipt_sha256<>terminal_sha
     THEN RETURN NULL; END IF;
  IF runtime.status='running' AND runtime.lease_until>clock_timestamp() THEN
    IF ack.status='running' AND ack.lease_token=runtime.lease_token
       AND ack.lease_until>clock_timestamp() THEN
      RETURN jsonb_build_object('runtimeLeaseToken',runtime.lease_token::text,
        'terminalStatus',a.status,'dispatchId',r.dispatch_id::text,
        'requestSha256',r.request_sha256,'attemptCount',ack.attempt_count);
    END IF;
    RETURN NULL;
  END IF;
  IF ack.status='running' AND ack.lease_until>clock_timestamp() THEN
    RETURN NULL;
  END IF;
  UPDATE creative_runtime_reconciliation_outbox SET status='running',
    lease_token=token,lease_until=clock_timestamp()+interval '2 minutes',
    attempt_count=attempt_count+1,last_error=NULL,updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id
     AND (status='pending' OR (status='running' AND lease_until<=clock_timestamp()));
  IF NOT FOUND THEN RETURN NULL; END IF;
  UPDATE creative_craft_launcher_ack_outbox SET status='running',lease_token=token,
    lease_until=clock_timestamp()+interval '2 minutes',
    attempt_count=attempt_count+1,last_error=NULL,updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND source_attempt_id=p_attempt_id
     AND (status='pending' OR (status='running' AND lease_until<=clock_timestamp()));
  IF NOT FOUND THEN RAISE EXCEPTION 'ACK claim lost after runtime claim' USING ERRCODE='40001'; END IF;
  SELECT * INTO ack FROM creative_craft_launcher_ack_outbox
   WHERE user_id=p_user_id AND source_attempt_id=p_attempt_id;
  RETURN jsonb_build_object('runtimeLeaseToken',token::text,
    'terminalStatus',a.status,'dispatchId',r.dispatch_id::text,
    'requestSha256',r.request_sha256,'attemptCount',ack.attempt_count);
END $$;

CREATE OR REPLACE FUNCTION creative_craft_ack_release(
  p_user_id uuid,p_attempt_id uuid,p_runtime_lease_token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; runtime record; ack record;
BEGIN
  PERFORM creative_craft_require_role('ack');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  PERFORM 1 FROM creative_execution_attempts WHERE user_id=p_user_id
    AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO runtime FROM creative_runtime_reconciliation_outbox
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT * INTO ack FROM creative_craft_launcher_ack_outbox
   WHERE user_id=p_user_id AND source_attempt_id=p_attempt_id FOR UPDATE;
  IF runtime.status<>'running' OR runtime.lease_token<>p_runtime_lease_token
     OR ack.status<>'running' OR ack.lease_token<>p_runtime_lease_token
     THEN RETURN false; END IF;
  UPDATE creative_craft_launcher_ack_outbox SET status='pending',lease_token=NULL,
    lease_until=NULL,last_error='transition_failed',updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND source_attempt_id=p_attempt_id
     AND status='running' AND lease_token=p_runtime_lease_token;
  UPDATE creative_runtime_reconciliation_outbox SET status='pending',
    lease_token=NULL,lease_until=NULL,last_error='transition_failed',
    available_at=clock_timestamp()+LEAST(3600,power(2,attempt_count))*interval '1 second',
    updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id
     AND status='running' AND lease_token=p_runtime_lease_token;
  RETURN FOUND;
END $$;

CREATE FUNCTION creative_craft_escrow_enqueue(
  p_user_id uuid,p_attempt_id uuid,p_candidate_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; a record; r record; runtime record; candidate record;
        artifacts jsonb; body jsonb; manifest jsonb; artifact_sha text;
        manifest_sha text; escrow uuid:=gen_random_uuid(); inserted integer;
BEGIN
  PERFORM creative_craft_require_role('escrow');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR u.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO a FROM creative_execution_attempts WHERE user_id=p_user_id
    AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO r FROM creative_craft_launcher_reservations WHERE user_id=p_user_id
    AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT * INTO runtime FROM creative_runtime_reconciliation_outbox
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT * INTO candidate FROM creative_candidate_receipts
   WHERE user_id=p_user_id AND id=p_candidate_id AND attempt_id=p_attempt_id FOR SHARE;
  IF a.status<>'succeeded' OR r.reserved_at IS NULL OR runtime.terminal_status<>'succeeded'
     OR candidate.id IS NULL OR jsonb_typeof(candidate.receipt->'outputs')<>'array'
     THEN RETURN NULL; END IF;
  SELECT jsonb_agg(item ORDER BY ordinal) INTO artifacts FROM (
    SELECT ordinal-1 AS ordinal,jsonb_build_object(
      'ordinal',ordinal-1,'kind','output',
      'relativePath',item->>'relativePath','role',item->>'role',
      'mimeType',item->>'mimeType','byteSize',(item->>'byteSize')::bigint,
      'sha256',item->>'sha256') AS item
      FROM jsonb_array_elements(candidate.receipt->'outputs')
        WITH ORDINALITY AS output(item,ordinal)
    UNION ALL
    SELECT jsonb_array_length(candidate.receipt->'outputs'),jsonb_build_object(
      'ordinal',jsonb_array_length(candidate.receipt->'outputs'),
      'kind','native_project',
      'relativePath',candidate.receipt#>>'{nativeProject,relativePath}',
      'role','native_project',
      'mimeType',candidate.receipt#>>'{nativeProject,mimeType}',
      'byteSize',(candidate.receipt#>>'{nativeProject,byteSize}')::bigint,
      'sha256',candidate.receipt#>>'{nativeProject,sha256}')
     WHERE a.craft_resolved_job_snapshot#>>'{engine,name}'
           IN ('filmcraft','photocraft')
  ) sealed;
  IF artifacts IS NULL OR jsonb_array_length(artifacts)<1 THEN RETURN NULL; END IF;
  artifact_sha:=creative_craft_json_sha256(artifacts);
  body:=jsonb_build_object('schemaVersion',1,'escrowId',escrow::text,
    'fence',jsonb_build_object('ownerUserId',p_user_id::text,
      'jobId',a.job_id::text,'stepId',a.step_id::text,'attemptId',a.id::text,
      'attemptNo',a.attempt_no,'claimLeaseToken',a.claim_lease_token::text,
      'fenceEpoch',a.fence_epoch,'admissionSha256',a.admission_sha256,
      'claimSetSha256',a.claim_set_sha256),
    'dispatchId',r.dispatch_id::text,'requestSha256',r.request_sha256,
    'authoritySha256',r.authority_sha256,
    'engine',jsonb_build_object(
      'name',a.craft_resolved_job_snapshot#>>'{engine,name}',
      'version',a.craft_resolved_job_snapshot#>>'{engine,version}',
      'operation',a.craft_resolved_job_snapshot->>'operation'),
    'artifacts',artifacts,'artifactManifestSha256',artifact_sha,
    'candidateResultSha256',candidate.craft_candidate_result_sha256,
    'pendingStorage',true,'publicationAuthorized',false);
  manifest_sha:=creative_craft_json_sha256(body);
  manifest:=body||jsonb_build_object('manifestSha256',manifest_sha);
  INSERT INTO creative_craft_output_adoption_outbox(
    user_id,escrow_id,source_attempt_id,candidate_id,job_id,source_step_id,
    attempt_no,claim_lease_token,fence_epoch,admission_sha256,claim_set_sha256,
    dispatch_id,request_sha256,authority_sha256,candidate_result_sha256,
    artifact_manifest_sha256,escrow_manifest_sha256,escrow_manifest,engine)
  VALUES(p_user_id,escrow,p_attempt_id,p_candidate_id,a.job_id,a.step_id,
    a.attempt_no,a.claim_lease_token,a.fence_epoch,a.admission_sha256,
    a.claim_set_sha256,r.dispatch_id,r.request_sha256,r.authority_sha256,
    candidate.craft_candidate_result_sha256,artifact_sha,manifest_sha,manifest,
    a.craft_resolved_job_snapshot#>>'{engine,name}')
  ON CONFLICT(user_id,source_attempt_id) DO NOTHING;
  GET DIAGNOSTICS inserted=ROW_COUNT;
  SELECT escrow_manifest INTO manifest FROM creative_craft_output_adoption_outbox
   WHERE user_id=p_user_id AND source_attempt_id=p_attempt_id;
  RETURN manifest;
END $$;

CREATE OR REPLACE FUNCTION creative_craft_escrow_defer_cleanup(
  p_user_id uuid,p_escrow_id uuid,p_version integer) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; peek record; job_row record; step_row record;
        attempt_row record; reservation_row record; runtime_row record;
        ack_row record; locked_row record;
BEGIN
  PERFORM creative_craft_require_role('escrow');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT * INTO peek FROM creative_craft_output_adoption_outbox
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(
    creative_craft_attempt_advisory_key(peek.source_attempt_id));
  SELECT * INTO job_row FROM creative_execution_jobs
   WHERE user_id=p_user_id AND id=peek.job_id FOR UPDATE;
  SELECT * INTO step_row FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=peek.job_id
     AND step_id=peek.source_step_id FOR UPDATE;
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=peek.source_attempt_id FOR UPDATE;
  SELECT * INTO reservation_row FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=peek.source_attempt_id FOR UPDATE;
  SELECT * INTO runtime_row FROM creative_runtime_reconciliation_outbox
   WHERE user_id=p_user_id AND attempt_id=peek.source_attempt_id FOR UPDATE;
  SELECT * INTO ack_row FROM creative_craft_launcher_ack_outbox
   WHERE user_id=p_user_id AND source_attempt_id=peek.source_attempt_id FOR UPDATE;
  SELECT * INTO locked_row FROM creative_craft_output_adoption_outbox
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id FOR UPDATE;
  IF job_row.id IS NULL OR step_row.step_id IS NULL OR attempt_row.id IS NULL
     OR reservation_row.attempt_id IS NULL OR runtime_row.attempt_id IS NULL
     OR locked_row.escrow_id IS NULL OR locked_row IS DISTINCT FROM peek
     OR locked_row.state<>'adopted' OR locked_row.version<>p_version
     OR step_row.kind<>'craft' OR NOT step_row.provider_call
     OR attempt_row.status<>'succeeded'
     OR reservation_row.compensation_status<>'confirmed'
     OR runtime_row.terminal_status<>'succeeded'
     OR (locked_row.job_id,locked_row.source_step_id,locked_row.attempt_no,
         locked_row.claim_lease_token,locked_row.fence_epoch,
         locked_row.admission_sha256,locked_row.claim_set_sha256) IS DISTINCT FROM
        (attempt_row.job_id,attempt_row.step_id,attempt_row.attempt_no,
         attempt_row.claim_lease_token,attempt_row.fence_epoch,
         attempt_row.admission_sha256,attempt_row.claim_set_sha256)
     OR (reservation_row.job_id,reservation_row.step_id,
         reservation_row.attempt_no,reservation_row.claim_lease_token,
         reservation_row.fence_epoch,reservation_row.admission_sha256,
         reservation_row.claim_set_sha256,reservation_row.dispatch_id,
         reservation_row.request_sha256,reservation_row.authority_sha256)
        IS DISTINCT FROM
        (locked_row.job_id,locked_row.source_step_id,locked_row.attempt_no,
         locked_row.claim_lease_token,locked_row.fence_epoch,
         locked_row.admission_sha256,locked_row.claim_set_sha256,
         locked_row.dispatch_id,locked_row.request_sha256,
         locked_row.authority_sha256)
     OR (runtime_row.job_id,runtime_row.step_id,runtime_row.attempt_no,
         runtime_row.claim_lease_token,runtime_row.fence_epoch,
         runtime_row.admission_sha256,runtime_row.claim_set_sha256)
        IS DISTINCT FROM
        (locked_row.job_id,locked_row.source_step_id,locked_row.attempt_no,
         locked_row.claim_lease_token,locked_row.fence_epoch,
         locked_row.admission_sha256,locked_row.claim_set_sha256)
     OR (ack_row.source_attempt_id IS NOT NULL AND
        (ack_row.job_id,ack_row.source_step_id,ack_row.attempt_no,
         ack_row.claim_lease_token,ack_row.fence_epoch,
         ack_row.admission_sha256,ack_row.claim_set_sha256,
         ack_row.dispatch_id,ack_row.request_sha256,ack_row.authority_sha256)
        IS DISTINCT FROM
        (locked_row.job_id,locked_row.source_step_id,locked_row.attempt_no,
         locked_row.claim_lease_token,locked_row.fence_epoch,
         locked_row.admission_sha256,locked_row.claim_set_sha256,
         locked_row.dispatch_id,locked_row.request_sha256,
         locked_row.authority_sha256)) THEN RETURN false; END IF;
  UPDATE creative_craft_output_adoption_outbox
     SET state='adopted',version=version+1,last_error='transition_failed',
         available_at=clock_timestamp()+interval '5 seconds',
         updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id
     AND state='adopted' AND version=p_version;
  RETURN FOUND;
END $$;

CREATE OR REPLACE FUNCTION creative_craft_escrow_release(
  p_user_id uuid,p_escrow_id uuid,p_version integer,p_lease_token uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; peek record; job_row record; step_row record;
        attempt_row record; reservation_row record; runtime_row record;
        ack_row record; locked_row record; prior text;
BEGIN
  PERFORM creative_craft_require_role('escrow');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT * INTO peek FROM creative_craft_output_adoption_outbox
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(
    creative_craft_attempt_advisory_key(peek.source_attempt_id));
  SELECT * INTO job_row FROM creative_execution_jobs
   WHERE user_id=p_user_id AND id=peek.job_id FOR UPDATE;
  SELECT * INTO step_row FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=peek.job_id
     AND step_id=peek.source_step_id FOR UPDATE;
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=peek.source_attempt_id FOR UPDATE;
  SELECT * INTO reservation_row FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=peek.source_attempt_id FOR UPDATE;
  SELECT * INTO runtime_row FROM creative_runtime_reconciliation_outbox
   WHERE user_id=p_user_id AND attempt_id=peek.source_attempt_id FOR UPDATE;
  SELECT * INTO ack_row FROM creative_craft_launcher_ack_outbox
   WHERE user_id=p_user_id AND source_attempt_id=peek.source_attempt_id FOR UPDATE;
  SELECT * INTO locked_row FROM creative_craft_output_adoption_outbox
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id FOR UPDATE;
  prior:=locked_row.state;
  IF job_row.id IS NULL OR step_row.step_id IS NULL OR attempt_row.id IS NULL
     OR reservation_row.attempt_id IS NULL OR runtime_row.attempt_id IS NULL
     OR locked_row.escrow_id IS NULL OR locked_row IS DISTINCT FROM peek
     OR prior NOT IN ('adopting','reconciling_cleanup')
     OR locked_row.version<>p_version OR locked_row.lease_token<>p_lease_token
     OR locked_row.lease_until<=clock_timestamp()
     OR step_row.kind<>'craft' OR NOT step_row.provider_call
     OR attempt_row.status<>'succeeded'
     OR reservation_row.compensation_status<>'confirmed'
     OR runtime_row.terminal_status<>'succeeded'
     OR (locked_row.job_id,locked_row.source_step_id,locked_row.attempt_no,
         locked_row.claim_lease_token,locked_row.fence_epoch,
         locked_row.admission_sha256,locked_row.claim_set_sha256) IS DISTINCT FROM
        (attempt_row.job_id,attempt_row.step_id,attempt_row.attempt_no,
         attempt_row.claim_lease_token,attempt_row.fence_epoch,
         attempt_row.admission_sha256,attempt_row.claim_set_sha256)
     OR (reservation_row.dispatch_id,reservation_row.request_sha256,
         reservation_row.authority_sha256) IS DISTINCT FROM
        (locked_row.dispatch_id,locked_row.request_sha256,
         locked_row.authority_sha256)
     OR (runtime_row.job_id,runtime_row.step_id,runtime_row.attempt_no,
         runtime_row.claim_lease_token,runtime_row.fence_epoch,
         runtime_row.admission_sha256,runtime_row.claim_set_sha256)
        IS DISTINCT FROM
        (locked_row.job_id,locked_row.source_step_id,locked_row.attempt_no,
         locked_row.claim_lease_token,locked_row.fence_epoch,
         locked_row.admission_sha256,locked_row.claim_set_sha256)
     OR (ack_row.source_attempt_id IS NOT NULL AND
        (ack_row.dispatch_id,ack_row.request_sha256,ack_row.authority_sha256)
        IS DISTINCT FROM
        (locked_row.dispatch_id,locked_row.request_sha256,
         locked_row.authority_sha256)) THEN RETURN false; END IF;
  UPDATE creative_craft_output_adoption_outbox
     SET state=CASE prior WHEN 'adopting' THEN 'pending_adoption'
                          ELSE 'reconciliation_pending' END,
         version=version+1,lease_token=NULL,lease_until=NULL,
         last_error='transition_failed',
         available_at=clock_timestamp()+interval '5 seconds',
         updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id AND state=prior
     AND version=p_version AND lease_token=p_lease_token
     AND lease_until>clock_timestamp();
  RETURN FOUND;
END $$;

-- Replace the frozen 113 implementation forward-only.  Its PL/pgSQL record
-- variable `q` collided with the quarantine table alias before the record was
-- assigned, making the nominal adoption -> reconciliation transition fail.
-- The replacement also applies the universal account/user/attempt lock order.
CREATE OR REPLACE FUNCTION creative_craft_escrow_schedule_cleanup(
  p_user_id uuid,p_escrow_id uuid,p_version integer) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE u record; original_row record; locked_row record; ack_row record;
        candidate_row record; ack_exact boolean:=false;
BEGIN
  PERFORM creative_craft_require_role('escrow');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO u FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT * INTO original_row FROM creative_craft_output_adoption_outbox
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(
    creative_craft_attempt_advisory_key(original_row.source_attempt_id));
  PERFORM 1 FROM creative_execution_jobs
   WHERE user_id=p_user_id AND id=original_row.job_id FOR UPDATE;
  PERFORM 1 FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=original_row.job_id
     AND step_id=original_row.source_step_id FOR UPDATE;
  PERFORM 1 FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=original_row.source_attempt_id FOR UPDATE;
  PERFORM 1 FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=original_row.source_attempt_id
   FOR UPDATE;
  PERFORM 1 FROM creative_runtime_reconciliation_outbox
   WHERE user_id=p_user_id AND attempt_id=original_row.source_attempt_id
   FOR UPDATE;
  SELECT * INTO ack_row FROM creative_craft_launcher_ack_outbox
   WHERE user_id=p_user_id
     AND source_attempt_id=original_row.source_attempt_id FOR UPDATE;
  SELECT * INTO locked_row FROM creative_craft_output_adoption_outbox
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id FOR UPDATE;
  IF NOT FOUND OR locked_row.state<>'adopted'
     OR locked_row.version<>p_version
     OR locked_row IS DISTINCT FROM original_row THEN RETURN false; END IF;
  ack_exact:=COALESCE(ack_row.status='done'
    AND ack_row.completed_at IS NOT NULL AND
    (ack_row.job_id,ack_row.source_step_id,ack_row.attempt_no,
     ack_row.claim_lease_token,ack_row.fence_epoch,ack_row.admission_sha256,
     ack_row.claim_set_sha256,ack_row.terminal_status,ack_row.dispatch_id,
     ack_row.request_sha256,ack_row.authority_sha256,ack_row.candidate_id,
     ack_row.quarantine_set_sha256,ack_row.adoption_attempt_id,
     ack_row.adoption_fence_epoch,ack_row.adoption_result_sha256)
      IS NOT DISTINCT FROM
    (original_row.job_id,original_row.source_step_id,original_row.attempt_no,
     original_row.claim_lease_token,original_row.fence_epoch,
     original_row.admission_sha256,original_row.claim_set_sha256,
     original_row.terminal_status,original_row.dispatch_id,
     original_row.request_sha256,original_row.authority_sha256,
     original_row.candidate_id,original_row.quarantine_set_sha256,
     original_row.adoption_attempt_id,original_row.adoption_fence_epoch,
     original_row.adoption_result_sha256),false);
  IF NOT ack_exact THEN
    SELECT candidate_state.state,candidate_state.quarantine_set_sha256,
           quarantine.quarantine_set_sha256 AS quarantine_set_sha256_q,
           quarantine.adoption_attempt_id,quarantine.adoption_fence_epoch,
           quarantine.adoption_result_sha256
      INTO candidate_row
      FROM creative_candidate_states candidate_state
      JOIN creative_candidate_quarantines quarantine
        ON quarantine.user_id=candidate_state.user_id
       AND quarantine.candidate_id=candidate_state.candidate_id
     WHERE candidate_state.user_id=p_user_id
       AND candidate_state.candidate_id=original_row.candidate_id;
    IF NOT FOUND OR candidate_row.state IS NULL
       OR candidate_row.state NOT IN
          ('quarantined','review_pending','blocked','approved_for_use',
           'revision_requested','released')
       OR candidate_row.quarantine_set_sha256 IS DISTINCT FROM
          original_row.quarantine_set_sha256
       OR (original_row.quarantine_set_sha256,
           original_row.adoption_attempt_id,original_row.adoption_fence_epoch,
           original_row.adoption_result_sha256) IS DISTINCT FROM
          (candidate_row.quarantine_set_sha256_q,
           candidate_row.adoption_attempt_id,candidate_row.adoption_fence_epoch,
           candidate_row.adoption_result_sha256) THEN RETURN false; END IF;
  END IF;
  UPDATE creative_craft_output_adoption_outbox
     SET state='reconciliation_pending',version=version+1,
         updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND escrow_id=p_escrow_id
     AND state='adopted' AND version=p_version;
  RETURN FOUND;
END $$;

-- A verifier persists physical evidence in a transaction that is deliberately
-- separate from business completion.  If the process dies in that gap, a
-- subsequent claim must classify the old evidence before changing the fence;
-- otherwise the immutable receipt has no durable consumer and account
-- deletion remains blocked forever.  Keep the original 113/114 claim bodies
-- private and wrap them in this transaction so their account -> users ->
-- attempt -> transition locks remain held while stale evidence is consumed.
ALTER FUNCTION creative_craft_preparer_claim_compensation(uuid,uuid)
  RENAME TO creative_craft_preparer_claim_compensation_raw114;
ALTER FUNCTION creative_craft_ack_claim(uuid,uuid)
  RENAME TO creative_craft_ack_claim_raw114;
ALTER FUNCTION creative_craft_escrow_claim(uuid,uuid)
  RENAME TO creative_craft_escrow_claim_raw114;

CREATE FUNCTION creative_craft_reject_stale_physical_receipts(
  p_user_id uuid,p_attempt_id uuid,p_phase text,p_keep_lease_token uuid,
  p_escrow_id uuid,p_keep_version integer) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE rejected integer;
BEGIN
  IF p_phase NOT IN ('prestart_forget','terminal_forget','adopt_copy')
     OR p_keep_lease_token IS NULL
     OR ((p_phase='adopt_copy') IS DISTINCT FROM (p_escrow_id IS NOT NULL))
     OR ((p_phase='adopt_copy') IS DISTINCT FROM (p_keep_version IS NOT NULL))
  THEN
    RAISE EXCEPTION 'stale physical receipt fence is not closed'
      USING ERRCODE='22023';
  END IF;
  INSERT INTO creative_craft_physical_receipt_consumptions(
    user_id,receipt_id,completion_kind,attempt_id,escrow_id,target_version)
  SELECT receipt.user_id,receipt.receipt_id,
         CASE p_phase WHEN 'prestart_forget' THEN 'compensation_rejected'
                      WHEN 'terminal_forget' THEN 'ack_rejected'
                      ELSE 'adoption_rejected' END,
         challenge.attempt_id,challenge.escrow_id,challenge.target_version
    FROM creative_craft_physical_receipts receipt
    JOIN creative_craft_physical_challenges challenge
      ON challenge.user_id=receipt.user_id
     AND challenge.challenge_id=receipt.challenge_id
   WHERE receipt.user_id=p_user_id AND challenge.attempt_id=p_attempt_id
     AND receipt.phase=p_phase
     AND (p_phase<>'adopt_copy' OR challenge.escrow_id=p_escrow_id)
     AND (challenge.target_lease_token IS DISTINCT FROM p_keep_lease_token
       OR (p_phase='adopt_copy' AND
           challenge.target_version IS DISTINCT FROM p_keep_version))
     AND NOT EXISTS (
       SELECT 1 FROM creative_craft_physical_receipt_consumptions consumed
        WHERE consumed.user_id=receipt.user_id
          AND consumed.receipt_id=receipt.receipt_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS rejected=ROW_COUNT;
  RETURN rejected;
END $$;

CREATE FUNCTION creative_craft_preparer_claim_compensation(
  p_user_id uuid,p_attempt_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE claimed jsonb; lease_token uuid:=gen_random_uuid();
        job_row record; step_row record; attempt_row record;
        reservation_row record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  claimed:=creative_craft_preparer_claim_compensation_raw114(
    p_user_id,p_attempt_id);
  IF claimed IS NULL THEN
    -- 113 intentionally rejected confirmed reservations.  Recovery 114 may
    -- forget one only after every execution lease expired and before provider
    -- dispatch; the raw call above already acquired account, user, attempt,
    -- job, step, attempt and reservation locks in canonical order.
    SELECT * INTO attempt_row FROM creative_execution_attempts
     WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT * INTO job_row FROM creative_execution_jobs
     WHERE user_id=p_user_id AND id=attempt_row.job_id FOR UPDATE;
    SELECT * INTO step_row FROM creative_execution_steps
     WHERE user_id=p_user_id AND job_id=attempt_row.job_id
       AND step_id=attempt_row.step_id FOR UPDATE;
    SELECT * INTO reservation_row FROM creative_craft_launcher_reservations
     WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR UPDATE;
    IF job_row.id IS NULL OR step_row.step_id IS NULL
       OR reservation_row.attempt_id IS NULL
       OR job_row.status<>'running' OR step_row.status<>'running'
       OR attempt_row.status<>'running'
       OR step_row.kind<>'craft' OR NOT step_row.provider_call
       OR attempt_row.provider_started_at IS NOT NULL
       OR attempt_row.provider_returned_at IS NOT NULL
       OR step_row.provider_started_at IS NOT NULL
       OR step_row.provider_returned_at IS NOT NULL
       OR reservation_row.reserved_at IS NULL
       OR NOT (reservation_row.compensation_status='confirmed' OR
          (reservation_row.compensation_status='running'
           AND reservation_row.compensation_lease_until<=clock_timestamp()))
       OR reservation_row.job_id<>attempt_row.job_id
       OR reservation_row.step_id<>attempt_row.step_id
       OR reservation_row.attempt_no<>attempt_row.attempt_no
       OR reservation_row.claim_lease_token<>
          attempt_row.claim_lease_token
       OR reservation_row.fence_epoch<>attempt_row.fence_epoch
       OR reservation_row.admission_sha256<>attempt_row.admission_sha256
       OR reservation_row.claim_set_sha256<>attempt_row.claim_set_sha256
       OR attempt_row.lease_until>clock_timestamp()
       OR step_row.lease_until>clock_timestamp()
       OR job_row.lease_until>clock_timestamp()
       OR attempt_row.lease_token IS DISTINCT FROM step_row.lease_token
       OR attempt_row.lease_token IS DISTINCT FROM job_row.lease_token
    THEN RETURN NULL; END IF;
    UPDATE creative_craft_launcher_reservations SET
      compensation_status='running',compensation_lease_token=lease_token,
      compensation_lease_until=clock_timestamp()+interval '2 minutes',
      compensation_attempt_count=compensation_attempt_count+1,
      compensation_last_error=NULL,updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND attempt_id=p_attempt_id
       AND (compensation_status='confirmed' OR
         (compensation_status='running'
          AND compensation_lease_until<=clock_timestamp()))
     RETURNING * INTO reservation_row;
    IF NOT FOUND THEN RETURN NULL; END IF;
    claimed:=jsonb_build_object(
      'leaseToken',lease_token,
      'attemptCount',reservation_row.compensation_attempt_count,
      'dispatchId',reservation_row.dispatch_id,
      'requestSha256',reservation_row.request_sha256,
      'inputRoot',reservation_row.input_root,
      'outputRoot',reservation_row.output_root);
  ELSE
    lease_token:=(claimed->>'leaseToken')::uuid;
  END IF;
  PERFORM creative_craft_reject_stale_physical_receipts(
    p_user_id,p_attempt_id,'prestart_forget',lease_token,NULL,NULL);
  RETURN claimed;
END $$;

CREATE FUNCTION creative_craft_ack_claim(
  p_user_id uuid,p_attempt_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE claimed jsonb; lease_token uuid;
BEGIN
  PERFORM creative_craft_require_role('ack');
  claimed:=creative_craft_ack_claim_raw114(p_user_id,p_attempt_id);
  IF claimed IS NULL THEN RETURN NULL; END IF;
  lease_token:=(claimed->>'runtimeLeaseToken')::uuid;
  PERFORM creative_craft_reject_stale_physical_receipts(
    p_user_id,p_attempt_id,'terminal_forget',lease_token,NULL,NULL);
  RETURN claimed;
END $$;

CREATE FUNCTION creative_craft_escrow_claim(
  p_user_id uuid,p_escrow_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE claimed jsonb; attempt_id uuid; lease_token uuid; target_version integer;
BEGIN
  PERFORM creative_craft_require_role('escrow');
  claimed:=creative_craft_escrow_claim_raw114(p_user_id,p_escrow_id);
  IF claimed IS NULL OR claimed->>'state'<>'adopting' THEN RETURN claimed; END IF;
  attempt_id:=(claimed->>'sourceAttemptId')::uuid;
  lease_token:=(claimed->>'leaseToken')::uuid;
  target_version:=(claimed->>'version')::integer;
  PERFORM creative_craft_reject_stale_physical_receipts(
    p_user_id,attempt_id,'adopt_copy',lease_token,p_escrow_id,target_version);
  RETURN claimed;
END $$;

CREATE FUNCTION creative_craft_transition_definer_write_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE transition_owner text; completion_owner text; deletion_authorized boolean;
BEGIN
  IF TG_OP='DELETE' THEN
    IF current_setting('uonify.deleting_user',true)=OLD.user_id::text THEN
      PERFORM pg_advisory_xact_lock(
        hashtextextended('uonify:account:'||OLD.user_id::text,0));
      SELECT true INTO deletion_authorized FROM users
       WHERE id=OLD.user_id AND deletion_requested_at IS NOT NULL
       FOR NO KEY UPDATE;
      IF coalesce(deletion_authorized,false) THEN RETURN OLD; END IF;
    END IF;
    RAISE EXCEPTION 'Craft transition rows are deleted only with their account'
      USING ERRCODE='42501';
  END IF;
  IF TG_TABLE_NAME='creative_runtime_reconciliation_outbox' THEN
    IF NEW.kind<>'craft' THEN RETURN NEW; END IF;
  END IF;
  SELECT transition.definer_role,physical.completion_definer_role
    INTO transition_owner,completion_owner
    FROM creative_craft_transition_installation_bindings transition
    JOIN creative_craft_physical_installation_bindings physical USING(installation_key);
  IF current_user NOT IN (transition_owner,completion_owner) THEN
    RAISE EXCEPTION 'Craft state writes require the scoped SECURITY DEFINER API'
      USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER creative_craft_reservation_definer_only
BEFORE INSERT OR UPDATE OR DELETE ON creative_craft_launcher_reservations
FOR EACH ROW EXECUTE FUNCTION creative_craft_transition_definer_write_guard();
CREATE TRIGGER creative_craft_runtime_definer_only
BEFORE INSERT OR UPDATE OR DELETE ON creative_runtime_reconciliation_outbox
FOR EACH ROW EXECUTE FUNCTION creative_craft_transition_definer_write_guard();
CREATE TRIGGER creative_craft_ack_definer_only
BEFORE INSERT OR UPDATE OR DELETE ON creative_craft_launcher_ack_outbox
FOR EACH ROW EXECUTE FUNCTION creative_craft_transition_definer_write_guard();
CREATE TRIGGER creative_craft_escrow_definer_only
BEFORE INSERT OR UPDATE OR DELETE ON creative_craft_output_adoption_outbox
FOR EACH ROW EXECUTE FUNCTION creative_craft_transition_definer_write_guard();

DO $privileges$
DECLARE s text:=current_schema(); row record; f record; role_name text;
        prep text; ack text; esc text; old_def text;
        vlaunch text; vstore text; physdef text; compdef text;
        caller_roles text; server_roles text; database_oid oid;
BEGIN
  SELECT t.preparer_role,t.ack_role,t.escrow_role,t.definer_role,
         p.launcher_verifier_role,p.storage_verifier_role,
         p.receipt_definer_role,p.completion_definer_role
    INTO prep,ack,esc,old_def,vlaunch,vstore,physdef,compdef
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p USING(installation_key);
  caller_roles:=format('%I,%I,%I,%I,%I',prep,ack,esc,vlaunch,vstore);
  server_roles:=format('%I,%I',physdef,compdef);
  SELECT oid INTO database_oid FROM pg_database WHERE datname=current_database();

  -- Revalidate the cluster identities and all shared dependencies immediately
  -- before any new grant.  The four inherited 113 roles legitimately retain
  -- only local Craft ownership/ACL; the four new roles are dependency-free.
  FOREACH role_name IN ARRAY ARRAY[prep,ack,esc,old_def,vlaunch,vstore,physdef,compdef] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles r WHERE r.rolname=role_name AND
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
              WHEN 'pg_namespace'::regclass THEN NOT EXISTS (
                SELECT 1 FROM pg_namespace namespace
                 WHERE namespace.oid=dependency.objid
                   AND namespace.nspname=s)
              WHEN 'pg_proc'::regclass THEN NOT EXISTS (
                SELECT 1 FROM pg_proc procedure
                JOIN pg_namespace namespace
                  ON namespace.oid=procedure.pronamespace
                 WHERE procedure.oid=dependency.objid
                   AND namespace.nspname=s
                   AND procedure.proname LIKE 'creative_craft_%')
              WHEN 'pg_class'::regclass THEN NOT EXISTS (
                SELECT 1 FROM pg_class relation
                JOIN pg_namespace namespace
                  ON namespace.oid=relation.relnamespace
                 WHERE relation.oid=dependency.objid
                   AND namespace.nspname=s
                   AND relation.relname IN (
                     'users','creative_execution_jobs',
                     'creative_execution_steps','creative_execution_attempts',
                     'creative_craft_launcher_reservations',
                     'creative_runtime_reconciliation_outbox',
                     'creative_craft_launcher_ack_outbox',
                     'creative_craft_output_adoption_outbox',
                     'creative_candidate_receipts',
                     'creative_candidate_states',
                     'creative_candidate_quarantines',
                     'creative_candidate_quarantine_assets',
                     'creative_candidate_native_projects',
                     'creative_native_project_revisions',
                     'creative_craft_transition_installation_bindings',
                     'creative_craft_physical_installation_bindings',
                     'creative_craft_physical_challenges',
                     'creative_craft_physical_receipts',
                     'creative_craft_physical_receipt_consumptions'))
              ELSE true END)))) THEN
      RAISE EXCEPTION 'Craft role changed before 114 grants: %',role_name
        USING ERRCODE='55000';
    END IF;
  END LOOP;

  FOR f IN SELECT p.oid::regprocedure signature,p.proname
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
    'creative_craft_preparer_append_reservation',
    'creative_craft_recover_expired_prestart','creative_craft_runtime_enqueue',
    'creative_craft_ack_claim','creative_craft_ack_release',
    'creative_craft_escrow_enqueue','creative_craft_issue_reserve_challenge',
    'creative_craft_issue_prestart_forget_challenge',
    'creative_craft_issue_terminal_forget_challenge',
    'creative_craft_issue_adopt_copy_challenge',
    'creative_craft_complete_reservation','creative_craft_complete_compensation',
    'creative_craft_complete_ack','creative_craft_complete_adoption',
    'creative_craft_complete_cleanup',
    'creative_craft_preparer_release_compensation',
    'creative_craft_preparer_claim_compensation',
    'creative_craft_escrow_schedule_cleanup',
    'creative_craft_escrow_defer_cleanup','creative_craft_escrow_release',
    'creative_craft_preparer_claim_compensation_raw114',
    'creative_craft_ack_claim_raw114','creative_craft_escrow_claim_raw114',
    'creative_craft_reject_stale_physical_receipts') LOOP
      EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.signature,compdef);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
    'creative_craft_launcher_challenge_load','creative_craft_storage_challenge_load',
    'creative_craft_verify_challenge','creative_craft_verify_reserve',
    'creative_craft_verify_prestart_forget','creative_craft_verify_terminal_forget',
    'creative_craft_verify_adopt_copy') LOOP
      EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.signature,physdef);
  END LOOP;

  -- Every definer created here captures a literal trusted path.  pg_temp is
  -- last so temporary shadow objects never resolve before the installation.
  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname LIKE 'creative_craft_%' LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path TO pg_catalog,%I,pg_temp',
                   f.signature,s);
  END LOOP;

  EXECUTE format('REVOKE ALL ON TABLE %I.creative_craft_physical_installation_bindings,%I.creative_craft_physical_challenges,%I.creative_craft_physical_receipts,%I.creative_craft_physical_receipt_consumptions FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',
    s,s,s,s,caller_roles);
  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname LIKE 'creative_craft_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',
      f.signature,caller_roles);
  END LOOP;
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO %s,%s',s,caller_roles,server_roles);

  EXECUTE format('GRANT SELECT ON %I.creative_craft_transition_installation_bindings,%I.creative_craft_physical_installation_bindings TO %I,%I,%I',s,s,old_def,physdef,compdef);
  EXECUTE format('GRANT SELECT,INSERT ON %I.creative_craft_physical_challenges TO %I',s,compdef);
  EXECUTE format('GRANT SELECT ON %I.creative_craft_physical_receipts,%I.creative_craft_physical_receipt_consumptions TO %I',s,s,compdef);
  EXECUTE format('GRANT INSERT ON %I.creative_craft_physical_receipt_consumptions TO %I',s,compdef);
  EXECUTE format('GRANT SELECT ON %I.creative_craft_physical_challenges,%I.creative_craft_physical_receipts TO %I',s,s,physdef);
  EXECUTE format('GRANT INSERT ON %I.creative_craft_physical_receipts TO %I',s,physdef);
  -- PostgreSQL requires one UPDATE column privilege for SELECT ... FOR
  -- SHARE/KEY SHARE.  These columns are immutable and the append-only guard
  -- rejects any real write; the grants exist only so the definers can lock.
  EXECUTE format('GRANT UPDATE(challenge_id) ON %I.creative_craft_physical_challenges TO %I,%I',s,physdef,compdef);
  EXECUTE format('GRANT UPDATE(receipt_id) ON %I.creative_craft_physical_receipts TO %I,%I',s,physdef,compdef);
  EXECUTE format('GRANT UPDATE(receipt_id) ON %I.creative_craft_physical_receipt_consumptions TO %I',s,compdef);

  -- Receipt persistence revalidates the server-owned fence while holding the
  -- universal account/user/attempt order.  UPDATE is limited to one guarded
  -- column per table only because PostgreSQL requires it for row-locking
  -- SELECTs; the transition write guards still reject real physical-definer
  -- updates.
  EXECUTE format('GRANT SELECT,UPDATE(deletion_requested_at) ON %I.users TO %I',s,physdef);
  EXECUTE format('GRANT SELECT,UPDATE(status) ON %I.creative_execution_attempts TO %I',s,physdef);
  EXECUTE format('GRANT SELECT,UPDATE(compensation_status) ON %I.creative_craft_launcher_reservations TO %I',s,physdef);
  EXECUTE format('GRANT SELECT,UPDATE(status) ON %I.creative_runtime_reconciliation_outbox TO %I',s,physdef);
  EXECUTE format('GRANT SELECT,UPDATE(status) ON %I.creative_craft_launcher_ack_outbox TO %I',s,physdef);
  EXECUTE format('GRANT SELECT,UPDATE(state) ON %I.creative_craft_output_adoption_outbox TO %I',s,physdef);

  EXECUTE format('GRANT SELECT(id,deletion_requested_at) ON %I.users TO %I',s,compdef);
  EXECUTE format('GRANT UPDATE(deletion_requested_at) ON %I.users TO %I',s,compdef);
  EXECUTE format('GRANT SELECT,UPDATE(status,error_code,finished_at,available_at,updated_at,lease_token,lease_owner,lease_until) ON %I.creative_execution_jobs TO %I',s,compdef);
  EXECUTE format('GRANT SELECT,UPDATE(status,error_code,finished_at,updated_at,lease_token,lease_owner,lease_until) ON %I.creative_execution_steps TO %I',s,compdef);
  EXECUTE format('GRANT SELECT,UPDATE(status,error_code,finished_at,updated_at,lease_token,lease_owner,lease_until) ON %I.creative_execution_attempts TO %I',s,compdef);
  EXECUTE format('GRANT SELECT,INSERT,UPDATE(reservation_receipt,reservation_receipt_sha256,reserved_at,compensation_status,compensation_lease_token,compensation_lease_until,compensation_attempt_count,compensation_last_error,compensation_receipt,compensation_receipt_sha256,compensated_at,updated_at) ON %I.creative_craft_launcher_reservations TO %I',s,compdef);
  EXECUTE format('GRANT SELECT,INSERT,UPDATE(status,lease_token,lease_until,attempt_count,last_error,available_at,updated_at,completed_at) ON %I.creative_runtime_reconciliation_outbox TO %I',s,compdef);
  EXECUTE format('GRANT SELECT,INSERT,UPDATE(status,lease_token,lease_until,attempt_count,last_error,available_at,updated_at,completed_at) ON %I.creative_craft_launcher_ack_outbox TO %I',s,compdef);
  EXECUTE format('GRANT SELECT,INSERT,UPDATE(state,version,lease_token,lease_until,attempt_count,quarantine_set_sha256,adoption_manifest_sha256,adoption_attempt_id,adoption_fence_epoch,adoption_result_sha256,cleanup_receipt,cleanup_receipt_sha256,last_error,available_at,updated_at,adopted_at,completed_at) ON %I.creative_craft_output_adoption_outbox TO %I',s,compdef);
  EXECUTE format('GRANT SELECT ON %I.creative_candidate_receipts,%I.creative_candidate_states,%I.creative_candidate_quarantines,%I.creative_candidate_quarantine_assets,%I.creative_candidate_native_projects,%I.creative_native_project_revisions TO %I',s,s,s,s,s,s,compdef);
  EXECUTE format('GRANT UPDATE(id) ON %I.creative_candidate_receipts TO %I',s,compdef);
  EXECUTE format('GRANT UPDATE(candidate_id) ON %I.creative_candidate_quarantines TO %I',s,compdef);

  -- Internal helpers are executable only by the two technical definers.
  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
    'creative_craft_canonical_json','creative_craft_json_sha256',
    'creative_craft_text_sha256','creative_craft_account_advisory_key',
    'creative_craft_attempt_advisory_key','creative_craft_expected_role',
    'creative_craft_require_role','creative_craft_verify_challenge') LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I,%I',f.signature,physdef,compdef);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
    'creative_craft_preparer_claim_compensation_raw114',
    'creative_craft_ack_claim_raw114','creative_craft_escrow_claim_raw114',
    'creative_craft_reject_stale_physical_receipts') LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I',f.signature,compdef);
  END LOOP;

  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_preparer_append_reservation(uuid,uuid,jsonb),%I.creative_craft_recover_expired_prestart(uuid,uuid,integer),%I.creative_craft_preparer_claim_compensation(uuid,uuid),%I.creative_craft_preparer_release_compensation(uuid,uuid,uuid),%I.creative_craft_issue_reserve_challenge(uuid,uuid),%I.creative_craft_issue_prestart_forget_challenge(uuid,uuid,uuid),%I.creative_craft_complete_reservation(uuid,uuid,uuid),%I.creative_craft_complete_compensation(uuid,uuid,uuid,uuid) TO %I',s,s,s,s,s,s,s,s,prep);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_runtime_enqueue(uuid,uuid),%I.creative_craft_ack_claim(uuid,uuid),%I.creative_craft_ack_release(uuid,uuid,uuid),%I.creative_craft_issue_terminal_forget_challenge(uuid,uuid,uuid),%I.creative_craft_complete_ack(uuid,uuid,uuid,uuid) TO %I',s,s,s,s,s,ack);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_escrow_enqueue(uuid,uuid,uuid),%I.creative_craft_escrow_shortlist(uuid),%I.creative_craft_escrow_claim(uuid,uuid),%I.creative_craft_escrow_schedule_cleanup(uuid,uuid,integer),%I.creative_craft_escrow_defer_cleanup(uuid,uuid,integer),%I.creative_craft_escrow_release(uuid,uuid,integer,uuid),%I.creative_craft_issue_adopt_copy_challenge(uuid,uuid,integer,uuid),%I.creative_craft_complete_adoption(uuid,uuid,integer,uuid,uuid),%I.creative_craft_complete_cleanup(uuid,uuid,integer,uuid) TO %I',s,s,s,s,s,s,s,s,s,esc);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_launcher_challenge_load(uuid),%I.creative_craft_verify_reserve(uuid),%I.creative_craft_verify_prestart_forget(uuid),%I.creative_craft_verify_terminal_forget(uuid) TO %I',s,s,s,s,vlaunch);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_storage_challenge_load(uuid),%I.creative_craft_verify_adopt_copy(uuid) TO %I',s,s,vstore);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_account_deletion_barrier(uuid) TO uonify_app_runtime',s);
END $privileges$;

-- The four roles created by this gate started dependency-free.  After grants,
-- every ownership/ACL dependency must remain local to this installation and
-- limited to the objects explicitly created or granted above.
DO $dependency_allowlist$
DECLARE s text:=current_schema(); database_oid oid;
BEGIN
  SELECT oid INTO database_oid FROM pg_database WHERE datname=current_database();
  IF EXISTS (
    SELECT 1 FROM pg_shdepend dependency
    JOIN pg_roles role ON role.oid=dependency.refobjid
    JOIN creative_craft_physical_installation_bindings physical ON true
    JOIN creative_craft_transition_installation_bindings transition
      USING(installation_key)
    WHERE role.rolname IN (
            transition.preparer_role,transition.ack_role,
            transition.escrow_role,transition.definer_role,
            physical.launcher_verifier_role,physical.storage_verifier_role,
            physical.receipt_definer_role,physical.completion_definer_role)
      AND dependency.refclassid='pg_authid'::regclass
      AND (
        dependency.dbid<>database_oid
        OR dependency.deptype NOT IN ('a','o')
        OR CASE dependency.classid
          WHEN 'pg_namespace'::regclass THEN NOT EXISTS (
            SELECT 1 FROM pg_namespace namespace
             WHERE namespace.oid=dependency.objid AND namespace.nspname=s)
          WHEN 'pg_proc'::regclass THEN NOT EXISTS (
            SELECT 1 FROM pg_proc procedure
            JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
             WHERE procedure.oid=dependency.objid AND namespace.nspname=s
               AND procedure.proname LIKE 'creative_craft_%')
          WHEN 'pg_class'::regclass THEN NOT EXISTS (
            SELECT 1 FROM pg_class relation
            JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
             WHERE relation.oid=dependency.objid AND namespace.nspname=s
               AND relation.relname IN (
                 'users','creative_execution_jobs','creative_execution_steps',
                 'creative_execution_attempts',
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
                 'creative_craft_physical_receipt_consumptions'))
          ELSE true END)) THEN
    RAISE EXCEPTION 'Craft physical role dependency escaped the 114 allowlist'
      USING ERRCODE='55000';
  END IF;
END $dependency_allowlist$;

-- Record the honest supported bootstrap state.  Reaching 114 proves that 113
-- already neutralized the fixed 112 bridge locally.  It cannot rescue a
-- second installation that failed closed in 110 before reaching this file;
-- concurrent cross-database baselines still require an external/control-DB
-- migrator lock because PostgreSQL advisory locks are database-local.
CREATE TABLE creative_craft_transition_bootstrap_attestations (
  installation_id uuid PRIMARY KEY,
  through_migration integer NOT NULL CHECK (through_migration=114),
  fixed_bridge_clean boolean NOT NULL CHECK (fixed_bridge_clean),
  same_database_atomic_runner_required boolean NOT NULL CHECK (same_database_atomic_runner_required),
  cross_database_external_lock_required boolean NOT NULL CHECK (cross_database_external_lock_required),
  attested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY(installation_id)
    REFERENCES creative_craft_physical_installation_bindings(installation_id)
);
INSERT INTO creative_craft_transition_bootstrap_attestations
SELECT installation_id,114,true,true,true
  FROM creative_craft_physical_installation_bindings;
REVOKE ALL ON creative_craft_transition_bootstrap_attestations FROM PUBLIC;

DO $closed$
BEGIN
  IF EXISTS (SELECT 1 FROM creative_craft_launcher_deployment_policies
              WHERE desired_active)
     OR EXISTS (SELECT 1 FROM creative_craft_transition_installation_bindings
                 WHERE desired_active)
     OR EXISTS (SELECT 1 FROM creative_craft_physical_installation_bindings
                 WHERE desired_active) THEN
    RAISE EXCEPTION 'Craft physical transition authority must remain inactive'
      USING ERRCODE='55000';
  END IF;
END $closed$;

