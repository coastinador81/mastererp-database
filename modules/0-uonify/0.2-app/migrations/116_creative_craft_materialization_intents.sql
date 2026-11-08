-- Forward-only, inactive Craft materialization intent authority.
--
-- The intent is durable before any filesystem write.  The physical plan is
-- then bound under the exact attempt fence, populated outside PostgreSQL, and
-- attached to a launcher reservation only after an installation-scoped
-- verifier receipt is persisted.  No route, worker, scheduler or runtime
-- installation is activated by this migration.

SELECT pg_advisory_xact_lock(hashtextextended('uonify-craft-launcher-roles-v1',0));
SELECT pg_advisory_xact_lock(hashtextextended('uonify-craft-transition-api-v1',0));
SELECT pg_advisory_xact_lock(hashtextextended('uonify-craft-transition-api-v2',0));
SELECT pg_advisory_xact_lock(hashtextextended('uonify-craft-physical-api-v1',0));
SELECT pg_advisory_xact_lock(hashtextextended('uonify-craft-materialization-v1',0));

CREATE FUNCTION creative_craft_sha1(p_value bytea) RETURNS bytea
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE message bytea:=p_value||decode('80','hex'); bit_length bigint;
        zero_count integer; suffix bytea:=decode(repeat('00',8),'hex');
        h0 bigint:=1732584193; h1 bigint:=4023233417;
        h2 bigint:=2562383102; h3 bigint:=271733878; h4 bigint:=3285377520;
        a bigint; b bigint; c bigint; d bigint; e bigint; f bigint; k bigint;
        temp bigint; word bigint; words bigint[]:=array_fill(0::bigint,ARRAY[80]);
        block_no integer; idx integer; round_no integer; encoded text;
BEGIN
  bit_length:=length(p_value)::bigint*8;
  zero_count:=(56-(length(message)%64)+64)%64;
  message:=message||decode(repeat('00',zero_count),'hex');
  FOR idx IN 0..7 LOOP
    suffix:=set_byte(suffix,7-idx,((bit_length>>(idx*8))&255)::integer);
  END LOOP;
  message:=message||suffix;
  FOR block_no IN 0..(length(message)/64-1) LOOP
    FOR idx IN 0..15 LOOP
      word:=0;
      FOR round_no IN 0..3 LOOP
        word:=(word<<8)|get_byte(message,block_no*64+idx*4+round_no);
      END LOOP;
      words[idx+1]:=word;
    END LOOP;
    FOR idx IN 16..79 LOOP
      word:=words[idx-2]#words[idx-7]#words[idx-13]#words[idx-15];
      words[idx+1]:=((word<<1)|(word>>31))&4294967295;
    END LOOP;
    a:=h0;b:=h1;c:=h2;d:=h3;e:=h4;
    FOR round_no IN 0..79 LOOP
      IF round_no<20 THEN
        f:=(b&c)|((~b)&d); k:=1518500249;
      ELSIF round_no<40 THEN
        f:=b#c#d; k:=1859775393;
      ELSIF round_no<60 THEN
        f:=(b&c)|(b&d)|(c&d); k:=2400959708;
      ELSE
        f:=b#c#d; k:=3395469782;
      END IF;
      temp:=((((a<<5)|(a>>27))&4294967295)+
             (f&4294967295)+e+k+words[round_no+1])&4294967295;
      e:=d;d:=c;c:=((b<<30)|(b>>2))&4294967295;b:=a;a:=temp;
    END LOOP;
    h0:=(h0+a)&4294967295;h1:=(h1+b)&4294967295;
    h2:=(h2+c)&4294967295;h3:=(h3+d)&4294967295;
    h4:=(h4+e)&4294967295;
  END LOOP;
  encoded:=lpad(to_hex(h0),8,'0')||lpad(to_hex(h1),8,'0')||
    lpad(to_hex(h2),8,'0')||lpad(to_hex(h3),8,'0')||lpad(to_hex(h4),8,'0');
  RETURN decode(encoded,'hex');
END $$;

CREATE FUNCTION creative_craft_uuid5(p_namespace uuid,p_name text) RETURNS uuid
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE bytes bytea; encoded text;
BEGIN
  bytes:=substring(creative_craft_sha1(
    uuid_send(p_namespace)||convert_to(p_name,'UTF8')) FROM 1 FOR 16);
  bytes:=set_byte(bytes,6,(get_byte(bytes,6)&15)|80);
  bytes:=set_byte(bytes,8,(get_byte(bytes,8)&63)|128);
  encoded:=encode(bytes,'hex');
  RETURN (substring(encoded,1,8)||'-'||substring(encoded,9,4)||'-'||
          substring(encoded,13,4)||'-'||substring(encoded,17,4)||'-'||
          substring(encoded,21,12))::uuid;
END $$;

CREATE TABLE creative_craft_materialization_intents (
  user_id uuid NOT NULL,
  intent_id uuid NOT NULL DEFAULT gen_random_uuid(),
  namespace_id uuid NOT NULL DEFAULT gen_random_uuid(),
  installation_id uuid NOT NULL,
  attempt_id uuid NOT NULL,
  job_id uuid NOT NULL,
  step_id uuid NOT NULL,
  attempt_no integer NOT NULL CHECK (attempt_no>0),
  claim_lease_token uuid NOT NULL,
  fence_epoch bigint NOT NULL CHECK (fence_epoch>0),
  admission_id uuid NOT NULL,
  admission_sha256 text NOT NULL CHECK (admission_sha256 ~ '^[0-9a-f]{64}$'),
  claim_set_sha256 text NOT NULL CHECK (claim_set_sha256 ~ '^[0-9a-f]{64}$'),
  dispatch_id uuid NOT NULL,
  plan_fence_sha256 text NOT NULL CHECK (plan_fence_sha256 ~ '^[0-9a-f]{64}$'),
  state text NOT NULL DEFAULT 'planned'
    CHECK (state IN ('planned','writing','attached','legacy_attached',
                     'cleanup_running','cleanup_committed','forgotten')),
  plan jsonb CHECK (plan IS NULL OR jsonb_typeof(plan)='object'),
  plan_sha256 text CHECK (plan_sha256 ~ '^[0-9a-f]{64}$'),
  request_sha256 text CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
  request_authority jsonb CHECK (
    request_authority IS NULL OR jsonb_typeof(request_authority)='object'),
  profile_sha256 text CHECK (profile_sha256 ~ '^[0-9a-f]{64}$'),
  authority_sha256 text CHECK (authority_sha256 ~ '^[0-9a-f]{64}$'),
  cleanup_lease_token uuid,
  cleanup_lease_until timestamptz,
  cleanup_attempt_count integer NOT NULL DEFAULT 0 CHECK (cleanup_attempt_count>=0),
  cleanup_last_error text,
  available_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  planned_at timestamptz,
  attached_at timestamptz,
  forgotten_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(user_id,intent_id),
  UNIQUE(intent_id),
  UNIQUE(user_id,attempt_id),
  UNIQUE(namespace_id),
  UNIQUE(dispatch_id),
  UNIQUE(user_id,intent_id,attempt_id),
  FOREIGN KEY(installation_id)
    REFERENCES creative_craft_physical_installation_bindings(installation_id),
  FOREIGN KEY(user_id,job_id,step_id,attempt_no,attempt_id,
              claim_lease_token,fence_epoch,admission_id,
              admission_sha256,claim_set_sha256)
    REFERENCES creative_execution_attempts
      (user_id,job_id,step_id,attempt_no,id,claim_lease_token,fence_epoch,
       admission_id,admission_sha256,claim_set_sha256),
  CHECK ((state='planned' OR (state='forgotten' AND planned_at IS NULL))=
         (plan IS NULL)),
  CHECK ((plan IS NULL)=(plan_sha256 IS NULL)),
  CHECK ((plan IS NULL)=(request_sha256 IS NULL)),
  CHECK ((plan IS NULL)=(request_authority IS NULL)),
  CHECK ((plan IS NULL)=(profile_sha256 IS NULL)),
  CHECK ((plan IS NULL)=(authority_sha256 IS NULL)),
  CHECK ((state IN ('cleanup_running','cleanup_committed'))=
         (cleanup_lease_token IS NOT NULL)),
  CHECK ((state IN ('cleanup_running','cleanup_committed'))=
         (cleanup_lease_until IS NOT NULL)),
  CHECK (state NOT IN ('attached','legacy_attached') OR attached_at IS NOT NULL),
  CHECK ((state='forgotten')=(forgotten_at IS NOT NULL))
);

CREATE INDEX creative_craft_materialization_cleanup
  ON creative_craft_materialization_intents
    (state,available_at,cleanup_lease_until,created_at)
  WHERE state IN ('writing','cleanup_running','cleanup_committed');

-- Upgrade any inactive 114 rows without pretending that their legacy paths
-- were planned by 116.  They are already attached and may only follow their
-- existing reserve/forget lifecycle.
WITH legacy AS (
  SELECT r.*,p.installation_id,gen_random_uuid() AS intent_id,
         gen_random_uuid() AS namespace_id
    FROM creative_craft_launcher_reservations r
    CROSS JOIN creative_craft_physical_installation_bindings p
), inserted AS (
  INSERT INTO creative_craft_materialization_intents(
    user_id,intent_id,namespace_id,installation_id,attempt_id,job_id,step_id,
    attempt_no,claim_lease_token,fence_epoch,admission_id,admission_sha256,
    claim_set_sha256,dispatch_id,plan_fence_sha256,state,plan,plan_sha256,
    request_sha256,request_authority,profile_sha256,authority_sha256,
    planned_at,attached_at)
  SELECT user_id,intent_id,namespace_id,installation_id,attempt_id,job_id,
    step_id,attempt_no,claim_lease_token,fence_epoch,admission_id,
    admission_sha256,claim_set_sha256,dispatch_id,
    creative_craft_json_sha256(jsonb_build_object(
      'schemaVersion',1,'intentId',intent_id::text,
      'namespaceId',namespace_id::text,'attemptId',attempt_id::text,
      'claimLeaseToken',claim_lease_token::text,'fenceEpoch',fence_epoch)),
    'legacy_attached',jsonb_build_object(
      'dispatchId',dispatch_id::text,'namespaceId',namespace_id::text,
      'profile',jsonb_build_object('profileId',profile_id),
      'controlDocument',control_document,'inputRoot',input_root,
      'outputRoot',output_root,'inputs',inputs,
      'expectedOutputs',expected_outputs,'limits',limits),
    creative_craft_json_sha256(jsonb_build_object(
      'dispatchId',dispatch_id::text,'namespaceId',namespace_id::text,
      'profile',jsonb_build_object('profileId',profile_id),
      'controlDocument',control_document,'inputRoot',input_root,
      'outputRoot',output_root,'inputs',inputs,
      'expectedOutputs',expected_outputs,'limits',limits)),
    request_sha256,request_authority,profile_sha256,authority_sha256,
    prepared_at,prepared_at
  FROM legacy RETURNING user_id,attempt_id,intent_id
)
SELECT count(*) FROM inserted;

ALTER TABLE creative_craft_launcher_reservations
  ADD COLUMN materialization_intent_id uuid;

-- The 114 guard intentionally rejects same-state writes.  Permit exactly the
-- one forward-only upgrade link while every pre-116 authority field remains
-- byte-identical; the strict 116 guard below makes the link immutable again.
CREATE OR REPLACE FUNCTION creative_craft_launcher_reservation_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.materialization_intent_id IS NULL
     AND NEW.materialization_intent_id IS NOT NULL
     AND (to_jsonb(OLD)-'materialization_intent_id') IS NOT DISTINCT FROM
         (to_jsonb(NEW)-'materialization_intent_id')
     AND EXISTS(SELECT 1 FROM creative_craft_materialization_intents i
       WHERE i.user_id=NEW.user_id AND i.attempt_id=NEW.attempt_id
         AND i.intent_id=NEW.materialization_intent_id
         AND i.state='legacy_attached') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'invalid creative craft launcher materialization upgrade'
    USING ERRCODE='55000';
END $$;
DO $backfill$
DECLARE s text:=current_schema(); compdef text;
BEGIN
  SELECT completion_definer_role INTO compdef
    FROM creative_craft_physical_installation_bindings;
  EXECUTE format(
    'GRANT UPDATE(materialization_intent_id) ON %I.creative_craft_launcher_reservations TO %I',
    s,compdef);
  EXECUTE format(
    'GRANT SELECT ON %I.creative_craft_materialization_intents TO %I',
    s,compdef);
  EXECUTE format('SET LOCAL ROLE %I',compdef);
  UPDATE creative_craft_launcher_reservations r
     SET materialization_intent_id=i.intent_id
    FROM creative_craft_materialization_intents i
   WHERE i.user_id=r.user_id AND i.attempt_id=r.attempt_id;
  RESET ROLE;
  EXECUTE format(
    'REVOKE UPDATE(materialization_intent_id) ON %I.creative_craft_launcher_reservations FROM %I',
    s,compdef);
END $backfill$;
ALTER TABLE creative_craft_launcher_reservations
  ALTER COLUMN materialization_intent_id SET NOT NULL,
  ADD CONSTRAINT creative_craft_launcher_materialization_unique
    UNIQUE(user_id,materialization_intent_id,attempt_id),
  ADD CONSTRAINT creative_craft_launcher_materialization_fk
    FOREIGN KEY(user_id,materialization_intent_id,attempt_id)
    REFERENCES creative_craft_materialization_intents(user_id,intent_id,attempt_id);

ALTER TABLE creative_craft_physical_challenges
  ADD COLUMN materialization_intent_id uuid,
  DROP CONSTRAINT creative_craft_physical_challenges_phase_check,
  DROP CONSTRAINT creative_craft_physical_challenges_check2,
  ADD CONSTRAINT creative_craft_physical_challenges_phase_check CHECK (phase IN
    ('reserve','prestart_forget','terminal_forget','adopt_copy',
     'materialization_populate','materialization_forget')),
  ADD CONSTRAINT creative_craft_physical_challenges_lease_check CHECK (
    (phase IN ('prestart_forget','terminal_forget','adopt_copy',
               'materialization_forget'))=(target_lease_token IS NOT NULL)),
  ADD CONSTRAINT creative_craft_physical_challenges_intent_check CHECK (
    (phase IN ('materialization_populate','materialization_forget'))=
      (materialization_intent_id IS NOT NULL)),
  ADD CONSTRAINT creative_craft_physical_challenges_intent_fk
    FOREIGN KEY(user_id,materialization_intent_id,attempt_id)
    REFERENCES creative_craft_materialization_intents(user_id,intent_id,attempt_id);
CREATE UNIQUE INDEX creative_craft_physical_one_materialization_challenge
  ON creative_craft_physical_challenges
    (user_id,phase,materialization_intent_id,target_lease_token)
    NULLS NOT DISTINCT
  WHERE phase IN ('materialization_populate','materialization_forget');

ALTER TABLE creative_craft_physical_receipts
  DROP CONSTRAINT creative_craft_physical_receipts_phase_check,
  ADD CONSTRAINT creative_craft_physical_receipts_phase_check CHECK (phase IN
    ('reserve','prestart_forget','terminal_forget','adopt_copy',
     'materialization_populate','materialization_forget'));
ALTER TABLE creative_craft_physical_receipt_consumptions
  DROP CONSTRAINT creative_craft_physical_receipt_consumpti_completion_kind_check,
  ADD CONSTRAINT creative_craft_physical_receipt_consumptions_completion_kind_check
    CHECK (completion_kind IN
      ('reservation','reservation_rejected','compensation','compensation_rejected',
       'ack','ack_rejected','adoption','adoption_rejected','cleanup',
       'materialization','materialization_rejected','materialization_cleanup'));

CREATE FUNCTION creative_craft_materialization_intent_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (OLD.user_id,OLD.intent_id,OLD.namespace_id,OLD.installation_id,
      OLD.attempt_id,OLD.job_id,OLD.step_id,OLD.attempt_no,
      OLD.claim_lease_token,OLD.fence_epoch,OLD.admission_id,
      OLD.admission_sha256,OLD.claim_set_sha256,OLD.dispatch_id,
      OLD.plan_fence_sha256,OLD.created_at)
     IS DISTINCT FROM
     (NEW.user_id,NEW.intent_id,NEW.namespace_id,NEW.installation_id,
      NEW.attempt_id,NEW.job_id,NEW.step_id,NEW.attempt_no,
      NEW.claim_lease_token,NEW.fence_epoch,NEW.admission_id,
      NEW.admission_sha256,NEW.claim_set_sha256,NEW.dispatch_id,
      NEW.plan_fence_sha256,NEW.created_at) THEN
    RAISE EXCEPTION 'Craft materialization intent identity is immutable'
      USING ERRCODE='55000';
  END IF;
  IF OLD.plan IS NOT NULL AND
     (OLD.plan,OLD.plan_sha256,OLD.request_sha256,OLD.request_authority,
      OLD.profile_sha256,OLD.authority_sha256,OLD.planned_at)
     IS DISTINCT FROM
     (NEW.plan,NEW.plan_sha256,NEW.request_sha256,NEW.request_authority,
      NEW.profile_sha256,NEW.authority_sha256,NEW.planned_at) THEN
    RAISE EXCEPTION 'Craft materialization plan is immutable'
      USING ERRCODE='55000';
  END IF;
  IF NEW.cleanup_attempt_count<OLD.cleanup_attempt_count THEN
    RAISE EXCEPTION 'Craft materialization cleanup attempts are monotonic'
      USING ERRCODE='55000';
  END IF;
  IF NOT ((OLD.state='planned' AND NEW.state IN ('writing','forgotten')) OR
          (OLD.state='writing' AND
             NEW.state IN ('attached','cleanup_running','forgotten')) OR
          (OLD.state='cleanup_running' AND
             NEW.state IN ('cleanup_running','writing','cleanup_committed')) OR
          (OLD.state='cleanup_committed' AND
             NEW.state IN ('cleanup_committed','forgotten')) OR
          (OLD.state IN ('attached','legacy_attached') AND
             NEW.state='forgotten') OR
          (OLD.state=NEW.state AND OLD.state IN ('planned','writing')))
  THEN RAISE EXCEPTION 'invalid Craft materialization intent transition'
    USING ERRCODE='55000'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER creative_craft_materialization_intent_guard
BEFORE UPDATE ON creative_craft_materialization_intents
FOR EACH ROW EXECUTE FUNCTION creative_craft_materialization_intent_guard();
CREATE TRIGGER creative_craft_materialization_definer_only
BEFORE INSERT OR UPDATE OR DELETE ON creative_craft_materialization_intents
FOR EACH ROW EXECUTE FUNCTION creative_craft_transition_definer_write_guard();

-- The 114 append accepts a post-I/O DTO and therefore cannot remain a caller
-- boundary.  Keep the frozen body only as an ungranted, unusable upgrade
-- artifact; the new NOT NULL/FK also prevents it from creating a reservation.
ALTER FUNCTION creative_craft_preparer_append_reservation(uuid,uuid,jsonb)
  RENAME TO creative_craft_preparer_append_reservation_raw114;

CREATE OR REPLACE FUNCTION creative_craft_launcher_reservation_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (OLD.user_id,OLD.attempt_id,OLD.job_id,OLD.step_id,OLD.attempt_no,
      OLD.claim_lease_token,OLD.fence_epoch,OLD.admission_id,
      OLD.admission_sha256,OLD.claim_set_sha256,OLD.dispatch_id,
      OLD.request_sha256,OLD.request_authority,OLD.profile_id,
      OLD.profile_sha256,OLD.control_document,OLD.input_root,OLD.output_root,
      OLD.inputs,OLD.expected_outputs,OLD.limits,OLD.authority_sha256,
      OLD.materialization_intent_id,OLD.prepared_at) IS DISTINCT FROM
     (NEW.user_id,NEW.attempt_id,NEW.job_id,NEW.step_id,NEW.attempt_no,
      NEW.claim_lease_token,NEW.fence_epoch,NEW.admission_id,
      NEW.admission_sha256,NEW.claim_set_sha256,NEW.dispatch_id,
      NEW.request_sha256,NEW.request_authority,NEW.profile_id,
      NEW.profile_sha256,NEW.control_document,NEW.input_root,NEW.output_root,
      NEW.inputs,NEW.expected_outputs,NEW.limits,NEW.authority_sha256,
      NEW.materialization_intent_id,NEW.prepared_at) THEN
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
  IF NOT ((OLD.compensation_status='pending' AND
            NEW.compensation_status IN ('running','confirmed')) OR
          (OLD.compensation_status='confirmed' AND
            NEW.compensation_status='running') OR
          (OLD.compensation_status='running' AND
            NEW.compensation_status IN ('running','compensated'))) THEN
    RAISE EXCEPTION 'invalid creative craft launcher compensation transition';
  END IF;
  RETURN NEW;
END $$;

CREATE FUNCTION creative_craft_materialization_begin(
  p_user_id uuid,p_attempt_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; install record; stored record; inserted integer;
        namespace uuid:=gen_random_uuid(); intent uuid:=gen_random_uuid();
        dispatch uuid; fence_hash text;
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
  SELECT installation_id INTO install
    FROM creative_craft_physical_installation_bindings;
  IF job_row.status<>'running' OR step_row.status<>'running'
     OR attempt_row.status<>'running' OR step_row.kind<>'craft'
     OR NOT step_row.provider_call
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR attempt_row.craft_authority_bound_at IS NULL
     OR attempt_row.lease_token IS DISTINCT FROM attempt_row.claim_lease_token
     OR attempt_row.lease_until<=clock_timestamp()
     OR step_row.lease_token IS DISTINCT FROM attempt_row.lease_token
     OR job_row.lease_token IS DISTINCT FROM attempt_row.lease_token
  THEN RETURN NULL; END IF;
  dispatch:=creative_craft_uuid5(
    '6ba7b811-9dad-11d1-80b4-00c04fd430c8'::uuid,
    'uonify:craft-launcher:v2:'||attempt_row.id::text||':'||
      attempt_row.claim_lease_token::text||':'||attempt_row.fence_epoch::text);
  fence_hash:=creative_craft_json_sha256(jsonb_build_object(
    'schemaVersion',1,'intentId',intent::text,'namespaceId',namespace::text,
    'ownerUserId',p_user_id::text,'attemptId',attempt_row.id::text,
    'claimLeaseToken',attempt_row.claim_lease_token::text,
    'fenceEpoch',attempt_row.fence_epoch,'dispatchId',dispatch::text));
  INSERT INTO creative_craft_materialization_intents(
    user_id,intent_id,namespace_id,installation_id,attempt_id,job_id,step_id,
    attempt_no,claim_lease_token,fence_epoch,admission_id,admission_sha256,
    claim_set_sha256,dispatch_id,plan_fence_sha256)
  VALUES(p_user_id,intent,namespace,install.installation_id,attempt_row.id,
    attempt_row.job_id,attempt_row.step_id,attempt_row.attempt_no,
    attempt_row.claim_lease_token,attempt_row.fence_epoch,
    attempt_row.admission_id,attempt_row.admission_sha256,
    attempt_row.claim_set_sha256,dispatch,fence_hash)
  ON CONFLICT(user_id,attempt_id) DO NOTHING;
  GET DIAGNOSTICS inserted=ROW_COUNT;
  SELECT * INTO stored FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR SHARE;
  IF stored.claim_lease_token<>attempt_row.claim_lease_token
     OR stored.fence_epoch<>attempt_row.fence_epoch
     OR stored.dispatch_id<>dispatch THEN
    RAISE EXCEPTION 'materialization intent conflicts with attempt fence'
      USING ERRCODE='40001';
  END IF;
  RETURN jsonb_build_object('created',inserted=1,
    'intentId',stored.intent_id::text,'namespaceId',stored.namespace_id::text,
    'dispatchId',stored.dispatch_id::text,'state',stored.state,
    'planFenceSha256',stored.plan_fence_sha256);
END $$;

CREATE FUNCTION creative_craft_materialization_bind_plan(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_plan jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record; keys text[]; plan_hash text;
        request_body jsonb; request_hash text; authority_body jsonb;
        authority_hash text; profile_hash text; namespace_pattern text;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  SELECT array_agg(key ORDER BY key) INTO keys FROM jsonb_object_keys(p_plan) key;
  IF jsonb_typeof(p_plan)<>'object' OR keys<>ARRAY[
       'controlDocument','dispatchId','expectedOutputs','inputRoot','inputs',
       'limits','namespaceId','outputRoot','profile']::text[]
     OR jsonb_typeof(p_plan->'profile')<>'object'
     OR jsonb_typeof(p_plan->'controlDocument')<>'object'
     OR jsonb_typeof(p_plan->'inputs')<>'array'
     OR jsonb_typeof(p_plan->'expectedOutputs')<>'array'
     OR jsonb_array_length(p_plan->'expectedOutputs')<1
     OR jsonb_typeof(p_plan->'limits')<>'object'
  THEN RAISE EXCEPTION 'materialization plan is not closed' USING ERRCODE='22023'; END IF;
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
  IF intent_row.intent_id IS NULL OR job_row.status<>'running'
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
  IF p_plan->>'dispatchId'<>intent_row.dispatch_id::text
     OR p_plan->>'namespaceId'<>intent_row.namespace_id::text
     OR p_plan->>'inputRoot'=p_plan->>'outputRoot'
     OR length(p_plan->>'inputRoot') NOT BETWEEN 1 AND 4096
     OR length(p_plan->>'outputRoot') NOT BETWEEN 1 AND 4096
     OR left(p_plan->>'inputRoot',1)<>'/' OR left(p_plan->>'outputRoot',1)<>'/'
  THEN RAISE EXCEPTION 'materialization plan does not match server intent'
    USING ERRCODE='22023'; END IF;
  namespace_pattern:='(^|/)'||intent_row.namespace_id::text||'(/|$)';
  IF (p_plan->>'inputRoot') !~ namespace_pattern
     OR (p_plan->>'outputRoot') !~ namespace_pattern THEN
    RAISE EXCEPTION 'materialization roots do not contain server namespace'
      USING ERRCODE='22023';
  END IF;
  request_body:=jsonb_build_object('schemaVersion',2,
    'dispatchId',intent_row.dispatch_id::text,
    'attempt',jsonb_build_object('ownerUserId',p_user_id::text,
      'jobId',attempt_row.job_id::text,'stepId',attempt_row.step_id::text,
      'attemptId',attempt_row.id::text,'attemptNo',attempt_row.attempt_no,
      'claimLeaseToken',attempt_row.claim_lease_token::text,
      'fenceEpoch',attempt_row.fence_epoch,
      'admissionSha256',attempt_row.admission_sha256,
      'claimSetSha256',attempt_row.claim_set_sha256),
    'authority',jsonb_build_object(
      'jobBindingSha256',attempt_row.craft_job_binding_sha256,
      'preflightSha256',attempt_row.craft_preflight_sha256,
      'adapterPlanSha256',attempt_row.craft_adapter_plan_sha256,
      'capabilityMatrixSha256',attempt_row.craft_capability_matrix_sha256,
      'contractSchemaSha256',attempt_row.craft_contract_schema_sha256,
      'adapterCompilerVersion',attempt_row.craft_adapter_compiler_version,
      'adapterSourceSha256',attempt_row.craft_adapter_source_sha256,
      'recipeSha256',attempt_row.craft_recipe_sha256,
      'inputManifestSha256',attempt_row.craft_resolved_input_manifest_sha256));
  request_hash:=creative_craft_json_sha256(request_body);
  plan_hash:=creative_craft_json_sha256(p_plan);
  profile_hash:=creative_craft_json_sha256(p_plan->'profile');
  authority_body:=jsonb_build_object('intentId',intent_row.intent_id::text,
    'namespaceId',intent_row.namespace_id::text,
    'planFenceSha256',intent_row.plan_fence_sha256,
    'dispatchId',intent_row.dispatch_id::text,'requestSha256',request_hash,
    'ownerUserId',p_user_id::text,'attemptId',p_attempt_id::text,
    'requestAuthority',request_body->'authority',
    'profileId',p_plan#>>'{profile,profileId}',
    'controlSha256',creative_craft_json_sha256(p_plan->'controlDocument'),
    'inputRoot',p_plan->>'inputRoot','outputRoot',p_plan->>'outputRoot',
    'inputs',p_plan->'inputs','expectedOutputs',p_plan->'expectedOutputs',
    'limits',p_plan->'limits');
  authority_hash:=creative_craft_json_sha256(authority_body);
  IF intent_row.state='writing' THEN
    IF intent_row.plan_sha256<>plan_hash THEN
      RAISE EXCEPTION 'materialization plan conflicts with durable intent'
        USING ERRCODE='40001';
    END IF;
  ELSIF intent_row.state='planned' THEN
    UPDATE creative_craft_materialization_intents SET state='writing',
      plan=p_plan,plan_sha256=plan_hash,request_sha256=request_hash,
      request_authority=request_body->'authority',profile_sha256=profile_hash,
      authority_sha256=authority_hash,planned_at=clock_timestamp(),
      updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND intent_id=p_intent_id AND state='planned';
  ELSE RETURN NULL; END IF;
  RETURN jsonb_build_object('intentId',intent_row.intent_id::text,
    'namespaceId',intent_row.namespace_id::text,
    'dispatchId',intent_row.dispatch_id::text,'state','writing',
    'planFenceSha256',intent_row.plan_fence_sha256,
    'planSha256',plan_hash,'request',jsonb_build_object(
      'body',request_body,'requestSha256',request_hash),
    'authoritySha256',authority_hash,'profileSha256',profile_hash);
END $$;

CREATE FUNCTION creative_craft_issue_materialization_populate_challenge(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; attempt_row record; intent_row record; install record;
        challenge uuid:=gen_random_uuid(); receipt uuid:=gen_random_uuid();
        binding jsonb; evidence jsonb; stored record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR owner_row.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND attempt_id=p_attempt_id
   FOR UPDATE;
  SELECT installation_id,verifier_policy_sha256 INTO install
    FROM creative_craft_physical_installation_bindings;
  IF intent_row.state<>'writing' OR attempt_row.status<>'running'
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR attempt_row.claim_lease_token<>intent_row.claim_lease_token
     OR attempt_row.fence_epoch<>intent_row.fence_epoch
     OR attempt_row.lease_until<=clock_timestamp()
  THEN RETURN NULL; END IF;
  binding:=jsonb_build_object('installationId',install.installation_id::text,
    'verifierPolicySha256',install.verifier_policy_sha256,
    'ownerUserId',p_user_id::text,'jobId',attempt_row.job_id::text,
    'stepId',attempt_row.step_id::text,'attemptId',attempt_row.id::text,
    'attemptNo',attempt_row.attempt_no,
    'claimLeaseTokenSha256',creative_craft_text_sha256(
      attempt_row.claim_lease_token::text),
    'fenceEpoch',attempt_row.fence_epoch,
    'admissionSha256',attempt_row.admission_sha256,
    'claimSetSha256',attempt_row.claim_set_sha256,
    'intentId',intent_row.intent_id::text,
    'namespaceId',intent_row.namespace_id::text,
    'dispatchId',intent_row.dispatch_id::text,
    'requestSha256',intent_row.request_sha256,
    'authoritySha256',intent_row.authority_sha256,
    'planFenceSha256',intent_row.plan_fence_sha256);
  evidence:=jsonb_build_object('planSha256',intent_row.plan_sha256,
    'materializationSha256',creative_craft_json_sha256(jsonb_build_object(
      'inputRoot',intent_row.plan->>'inputRoot',
      'outputRoot',intent_row.plan->>'outputRoot',
      'inputs',intent_row.plan->'inputs',
      'expectedOutputs',intent_row.plan->'expectedOutputs',
      'limits',intent_row.plan->'limits')),
    'inputTreeSha256',creative_craft_json_sha256(intent_row.plan->'inputs'),
    'outputTreeSha256',creative_craft_json_sha256(
      intent_row.plan->'expectedOutputs'),
    'ownershipMarkerSha256',creative_craft_json_sha256(jsonb_build_object(
      'ownerUserId',p_user_id::text,'attemptId',p_attempt_id::text,
      'intentId',p_intent_id::text,
      'namespaceId',intent_row.namespace_id::text)));
  INSERT INTO creative_craft_physical_challenges(
    user_id,challenge_id,receipt_id,installation_id,phase,attempt_id,
    materialization_intent_id,binding,evidence,verifier_proof,issued_role)
  VALUES(p_user_id,challenge,receipt,install.installation_id,
    'materialization_populate',p_attempt_id,p_intent_id,binding,evidence,
    jsonb_build_object('plan',intent_row.plan,
      'planFenceSha256',intent_row.plan_fence_sha256),
    current_setting('role',true))
  ON CONFLICT DO NOTHING;
  SELECT * INTO stored FROM creative_craft_physical_challenges
   WHERE user_id=p_user_id AND phase='materialization_populate'
     AND materialization_intent_id=p_intent_id;
  RETURN jsonb_build_object('challengeId',stored.challenge_id::text,
    'receiptId',stored.receipt_id::text,'phase',stored.phase,
    'binding',stored.binding,'evidence',stored.evidence,
    'proof',stored.verifier_proof);
END $$;

CREATE FUNCTION creative_craft_materialization_finalize(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_receipt_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record; proof record; inserted integer;
        stored record;
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
  SELECT receipt.*,challenge.materialization_intent_id,challenge.attempt_id,
         challenge.binding,challenge.evidence INTO proof
    FROM creative_craft_physical_receipts receipt
    JOIN creative_craft_physical_challenges challenge
      ON challenge.user_id=receipt.user_id
     AND challenge.challenge_id=receipt.challenge_id
   WHERE receipt.user_id=p_user_id AND receipt.receipt_id=p_receipt_id
     AND receipt.phase='materialization_populate' FOR SHARE OF receipt,challenge;
  IF intent_row.state='attached' THEN
    IF proof.receipt_id IS NULL
       OR proof.materialization_intent_id<>p_intent_id
       OR proof.attempt_id<>p_attempt_id
       OR NOT EXISTS(
         SELECT 1 FROM creative_craft_physical_receipt_consumptions consumed
          WHERE consumed.user_id=p_user_id
            AND consumed.receipt_id=p_receipt_id
            AND consumed.attempt_id=p_attempt_id
            AND consumed.completion_kind='materialization') THEN
      RETURN NULL;
    END IF;
    SELECT * INTO stored FROM creative_craft_launcher_reservations
     WHERE user_id=p_user_id AND attempt_id=p_attempt_id;
    RETURN jsonb_build_object('created',false,'intentId',p_intent_id::text,
      'state','attached','request',jsonb_build_object(
        'body',jsonb_build_object('schemaVersion',2,
          'dispatchId',stored.dispatch_id::text,'attempt',jsonb_build_object(
            'ownerUserId',stored.user_id::text,'jobId',stored.job_id::text,
            'stepId',stored.step_id::text,'attemptId',stored.attempt_id::text,
            'attemptNo',stored.attempt_no,
            'claimLeaseToken',stored.claim_lease_token::text,
            'fenceEpoch',stored.fence_epoch,
            'admissionSha256',stored.admission_sha256,
            'claimSetSha256',stored.claim_set_sha256),
          'authority',stored.request_authority),
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
     OR proof.receipt_id IS NULL OR proof.materialization_intent_id<>p_intent_id
     OR proof.attempt_id<>p_attempt_id
     OR proof.binding->>'planFenceSha256'<>intent_row.plan_fence_sha256
     OR proof.evidence->>'planSha256'<>intent_row.plan_sha256
     OR EXISTS(SELECT 1 FROM creative_craft_physical_receipt_consumptions c
                WHERE c.user_id=p_user_id AND c.receipt_id=p_receipt_id)
  THEN RETURN NULL; END IF;
  INSERT INTO creative_craft_launcher_reservations(
    user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,fence_epoch,
    admission_id,admission_sha256,claim_set_sha256,dispatch_id,request_sha256,
    request_authority,profile_id,profile_sha256,control_document,input_root,
    output_root,inputs,expected_outputs,limits,authority_sha256,
    materialization_intent_id)
  VALUES(p_user_id,p_attempt_id,intent_row.job_id,intent_row.step_id,
    intent_row.attempt_no,intent_row.claim_lease_token,intent_row.fence_epoch,
    intent_row.admission_id,intent_row.admission_sha256,
    intent_row.claim_set_sha256,intent_row.dispatch_id,
    intent_row.request_sha256,intent_row.request_authority,
    intent_row.plan#>>'{profile,profileId}',intent_row.profile_sha256,
    intent_row.plan->'controlDocument',intent_row.plan->>'inputRoot',
    intent_row.plan->>'outputRoot',intent_row.plan->'inputs',
    intent_row.plan->'expectedOutputs',intent_row.plan->'limits',
    intent_row.authority_sha256,intent_row.intent_id)
  ON CONFLICT(user_id,attempt_id) DO NOTHING;
  GET DIAGNOSTICS inserted=ROW_COUNT;
  SELECT * INTO stored FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR SHARE;
  IF stored.materialization_intent_id<>p_intent_id
     OR stored.request_sha256<>intent_row.request_sha256
     OR stored.authority_sha256<>intent_row.authority_sha256 THEN
    RAISE EXCEPTION 'launcher reservation conflicts with materialization intent'
      USING ERRCODE='40001';
  END IF;
  INSERT INTO creative_craft_physical_receipt_consumptions(
    user_id,receipt_id,completion_kind,attempt_id)
  VALUES(p_user_id,p_receipt_id,'materialization',p_attempt_id);
  UPDATE creative_craft_materialization_intents SET state='attached',
    attached_at=clock_timestamp(),updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND state='writing';
  RETURN jsonb_build_object('created',inserted=1,
    'intentId',p_intent_id::text,'state','attached',
    'request',jsonb_build_object('body',jsonb_build_object(
      'schemaVersion',2,'dispatchId',stored.dispatch_id::text,
      'attempt',jsonb_build_object('ownerUserId',stored.user_id::text,
        'jobId',stored.job_id::text,'stepId',stored.step_id::text,
        'attemptId',stored.attempt_id::text,'attemptNo',stored.attempt_no,
        'claimLeaseToken',stored.claim_lease_token::text,
        'fenceEpoch',stored.fence_epoch,
        'admissionSha256',stored.admission_sha256,
        'claimSetSha256',stored.claim_set_sha256),
      'authority',stored.request_authority),
      'requestSha256',stored.request_sha256),
    'authoritySha256',stored.authority_sha256,
    'profileSha256',stored.profile_sha256);
END $$;

CREATE FUNCTION creative_craft_materialization_claim_cleanup(
  p_user_id uuid,p_intent_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record;
        token uuid:=gen_random_uuid();
        until_at timestamptz; deletion_cleanup boolean;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT attempt_id,job_id,step_id INTO seed
    FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(seed.attempt_id));
  SELECT * INTO job_row FROM creative_execution_jobs
   WHERE user_id=p_user_id AND id=seed.job_id FOR UPDATE;
  SELECT * INTO step_row FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=seed.job_id AND step_id=seed.step_id
   FOR UPDATE;
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=seed.attempt_id FOR UPDATE;
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id FOR UPDATE;
  deletion_cleanup:=owner_row.deletion_requested_at IS NOT NULL;
  IF attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR (NOT deletion_cleanup AND (
       job_row.status<>'running' OR step_row.status<>'running'
       OR attempt_row.status<>'running' OR step_row.kind<>'craft'
       OR NOT step_row.provider_call OR intent_row.available_at>clock_timestamp()
       OR job_row.lease_until>clock_timestamp()
       OR step_row.lease_until>clock_timestamp()
       OR attempt_row.lease_until>clock_timestamp()
       OR job_row.lease_token IS DISTINCT FROM attempt_row.lease_token
       OR step_row.lease_token IS DISTINCT FROM attempt_row.lease_token))
  THEN RETURN NULL; END IF;
  IF intent_row.state='planned' THEN
    UPDATE creative_craft_materialization_intents SET state='forgotten',
      forgotten_at=clock_timestamp(),updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND intent_id=p_intent_id AND state='planned';
    RETURN jsonb_build_object('intentId',p_intent_id::text,
      'attemptId',intent_row.attempt_id::text,'state','forgotten',
      'physicalRequired',false);
  END IF;
  IF intent_row.state IN ('cleanup_running','cleanup_committed')
     AND intent_row.cleanup_lease_until>clock_timestamp() THEN RETURN NULL; END IF;
  IF intent_row.state NOT IN ('writing','cleanup_running','cleanup_committed')
  THEN RETURN NULL; END IF;
  until_at:=clock_timestamp()+interval '5 minutes';
  UPDATE creative_craft_materialization_intents SET
    state=CASE WHEN state='cleanup_committed'
               THEN 'cleanup_committed' ELSE 'cleanup_running' END,
    cleanup_lease_token=token,cleanup_lease_until=until_at,
    cleanup_attempt_count=cleanup_attempt_count+1,
    cleanup_last_error=NULL,updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND (state='writing' OR
          (state IN ('cleanup_running','cleanup_committed')
           AND cleanup_lease_until<=clock_timestamp()));
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('intentId',p_intent_id::text,
    'attemptId',intent_row.attempt_id::text,
    'namespaceId',intent_row.namespace_id::text,
    'dispatchId',intent_row.dispatch_id::text,'state',
      CASE WHEN intent_row.state='cleanup_committed'
           THEN 'cleanup_committed' ELSE 'cleanup_running' END,
    'physicalRequired',true,'cleanupLeaseToken',token::text,
    'cleanupLeaseUntil',to_char(until_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'plan',intent_row.plan,
    'planFenceSha256',intent_row.plan_fence_sha256,
    'planSha256',intent_row.plan_sha256);
END $$;

CREATE FUNCTION creative_craft_materialization_commit_cleanup(
  p_user_id uuid,p_intent_id uuid,p_lease_token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT attempt_id,job_id,step_id INTO seed
    FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(
    creative_craft_attempt_advisory_key(seed.attempt_id));
  SELECT * INTO job_row FROM creative_execution_jobs
   WHERE user_id=p_user_id AND id=seed.job_id FOR UPDATE;
  SELECT * INTO step_row FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=seed.job_id AND step_id=seed.step_id
   FOR UPDATE;
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=seed.attempt_id FOR UPDATE;
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id FOR UPDATE;
  IF attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR intent_row.cleanup_lease_token<>p_lease_token
     OR intent_row.cleanup_lease_until<=clock_timestamp()
     OR intent_row.state NOT IN ('cleanup_running','cleanup_committed')
  THEN RETURN false; END IF;
  IF intent_row.state='cleanup_committed' THEN RETURN true; END IF;
  UPDATE creative_craft_materialization_intents
     SET state='cleanup_committed',updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND state='cleanup_running' AND cleanup_lease_token=p_lease_token
     AND cleanup_lease_until>clock_timestamp();
  RETURN FOUND;
END $$;

CREATE FUNCTION creative_craft_materialization_release_cleanup(
  p_user_id uuid,p_intent_id uuid,p_lease_token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT attempt_id INTO seed FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(seed.attempt_id));
  PERFORM 1 FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=seed.attempt_id FOR UPDATE;
  UPDATE creative_craft_materialization_intents SET state='writing',
    cleanup_lease_token=NULL,cleanup_lease_until=NULL,
    cleanup_last_error='cleanup_released',
    available_at=clock_timestamp()+interval '5 seconds',
    updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND state='cleanup_running' AND cleanup_lease_token=p_lease_token;
  RETURN FOUND;
END $$;

CREATE FUNCTION creative_craft_issue_materialization_forget_challenge(
  p_user_id uuid,p_intent_id uuid,p_lease_token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; attempt_row record; intent_row record;
        install record; challenge uuid:=gen_random_uuid();
        receipt uuid:=gen_random_uuid(); binding jsonb; evidence jsonb;
        stored record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT attempt_id INTO seed FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(seed.attempt_id));
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=seed.attempt_id FOR UPDATE;
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id FOR UPDATE;
  SELECT installation_id,verifier_policy_sha256 INTO install
    FROM creative_craft_physical_installation_bindings;
  IF intent_row.state<>'cleanup_committed'
     OR intent_row.cleanup_lease_token<>p_lease_token
     OR intent_row.cleanup_lease_until<=clock_timestamp()
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL THEN RETURN NULL; END IF;
  binding:=jsonb_build_object('installationId',install.installation_id::text,
    'verifierPolicySha256',install.verifier_policy_sha256,
    'ownerUserId',p_user_id::text,'jobId',intent_row.job_id::text,
    'stepId',intent_row.step_id::text,'attemptId',intent_row.attempt_id::text,
    'attemptNo',intent_row.attempt_no,
    'claimLeaseTokenSha256',creative_craft_text_sha256(
      intent_row.claim_lease_token::text),
    'fenceEpoch',intent_row.fence_epoch,
    'admissionSha256',intent_row.admission_sha256,
    'claimSetSha256',intent_row.claim_set_sha256,
    'intentId',intent_row.intent_id::text,
    'namespaceId',intent_row.namespace_id::text,
    'dispatchId',intent_row.dispatch_id::text,
    'requestSha256',intent_row.request_sha256,
    'authoritySha256',intent_row.authority_sha256,
    'planFenceSha256',intent_row.plan_fence_sha256);
  evidence:=jsonb_build_object('planSha256',intent_row.plan_sha256,
    'beforeTreeSha256',creative_craft_json_sha256(jsonb_build_object(
      'inputs',intent_row.plan->'inputs',
      'expectedOutputs',intent_row.plan->'expectedOutputs')),
    'tombstoneSha256',creative_craft_json_sha256(jsonb_build_object(
      'schemaVersion',1,
      'installationId',install.installation_id::text,
      'intentId',intent_row.intent_id::text,
      'namespaceId',intent_row.namespace_id::text,
      'planSha256',intent_row.plan_sha256)),
    'journalEntrySha256',creative_craft_json_sha256(jsonb_build_object(
      'tombstoneSha256',creative_craft_json_sha256(jsonb_build_object(
        'schemaVersion',1,
        'installationId',install.installation_id::text,
        'intentId',intent_row.intent_id::text,
        'namespaceId',intent_row.namespace_id::text,
        'planSha256',intent_row.plan_sha256)),
      'dataNamespaceAbsent',true)));
  INSERT INTO creative_craft_physical_challenges(
    user_id,challenge_id,receipt_id,installation_id,phase,attempt_id,
    materialization_intent_id,target_lease_token,binding,evidence,
    verifier_proof,issued_role)
  VALUES(p_user_id,challenge,receipt,install.installation_id,
    'materialization_forget',intent_row.attempt_id,p_intent_id,p_lease_token,
    binding,evidence,jsonb_build_object('plan',intent_row.plan,
      'planFenceSha256',intent_row.plan_fence_sha256),
    current_setting('role',true))
  ON CONFLICT DO NOTHING;
  SELECT * INTO stored FROM creative_craft_physical_challenges
   WHERE user_id=p_user_id AND phase='materialization_forget'
     AND materialization_intent_id=p_intent_id
     AND target_lease_token=p_lease_token;
  RETURN jsonb_build_object('challengeId',stored.challenge_id::text,
    'receiptId',stored.receipt_id::text,'phase',stored.phase,
    'binding',stored.binding,'evidence',stored.evidence,
    'proof',stored.verifier_proof);
END $$;

CREATE OR REPLACE FUNCTION creative_craft_launcher_challenge_load(
  p_challenge_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE row record;
BEGIN
  PERFORM creative_craft_require_role('launcher_verifier');
  SELECT * INTO row FROM creative_craft_physical_challenges
   WHERE challenge_id=p_challenge_id AND phase IN
    ('reserve','prestart_forget','terminal_forget',
     'materialization_populate','materialization_forget');
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('challengeId',row.challenge_id::text,
    'receiptId',row.receipt_id::text,'phase',row.phase,
    'binding',row.binding,'evidence',row.evidence,'proof',row.verifier_proof);
END $$;

CREATE FUNCTION creative_craft_verify_materialization_challenge(
  p_challenge_id uuid,p_phase text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE challenge record; prior record; owner_row record; attempt_row record;
        intent_row record; current_fence boolean:=false; body jsonb;
        observed timestamptz; receipt_hash text;
BEGIN
  PERFORM creative_craft_require_role('launcher_verifier');
  IF p_phase NOT IN ('materialization_populate','materialization_forget') THEN
    RAISE EXCEPTION 'invalid materialization verification phase'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO challenge FROM creative_craft_physical_challenges
   WHERE challenge_id=p_challenge_id AND phase=p_phase;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(
    creative_craft_account_advisory_key(challenge.user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=challenge.user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR (p_phase='materialization_populate'
                    AND owner_row.deletion_requested_at IS NOT NULL)
  THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(
    creative_craft_attempt_advisory_key(challenge.attempt_id));
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=challenge.user_id AND id=challenge.attempt_id FOR KEY SHARE;
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=challenge.user_id
     AND intent_id=challenge.materialization_intent_id
     AND attempt_id=challenge.attempt_id;
  SELECT * INTO challenge FROM creative_craft_physical_challenges
   WHERE challenge_id=p_challenge_id AND phase=p_phase FOR KEY SHARE;
  SELECT * INTO prior FROM creative_craft_physical_receipts
   WHERE user_id=challenge.user_id
     AND challenge_id=challenge.challenge_id
     AND phase=challenge.phase;
  IF FOUND THEN RETURN jsonb_build_object('body',prior.body,
    'receiptSha256',prior.receipt_sha256,
    'observedAt',to_char(prior.observed_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')); END IF;
  IF p_phase='materialization_populate' THEN
    current_fence:=intent_row.state='writing'
      AND attempt_row.status='running'
      AND attempt_row.provider_started_at IS NULL
      AND attempt_row.provider_returned_at IS NULL
      AND attempt_row.claim_lease_token=intent_row.claim_lease_token
      AND attempt_row.fence_epoch=intent_row.fence_epoch
      AND attempt_row.lease_until>clock_timestamp()
      AND challenge.binding->>'planFenceSha256'=intent_row.plan_fence_sha256
      AND challenge.evidence->>'planSha256'=intent_row.plan_sha256;
  ELSE
    current_fence:=intent_row.state='cleanup_committed'
      AND attempt_row.provider_started_at IS NULL
      AND attempt_row.provider_returned_at IS NULL
      AND intent_row.cleanup_lease_token=challenge.target_lease_token
      AND intent_row.cleanup_lease_until>clock_timestamp()
      AND challenge.binding->>'planFenceSha256'=intent_row.plan_fence_sha256
      AND challenge.evidence->>'planSha256'=intent_row.plan_sha256;
  END IF;
  IF NOT coalesce(current_fence,false) THEN RETURN NULL; END IF;
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
    current_setting('role',true)) ON CONFLICT DO NOTHING;
  SELECT * INTO prior FROM creative_craft_physical_receipts
   WHERE user_id=challenge.user_id
     AND challenge_id=challenge.challenge_id
     AND phase=challenge.phase;
  RETURN jsonb_build_object('body',prior.body,
    'receiptSha256',prior.receipt_sha256,
    'observedAt',to_char(prior.observed_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
END $$;

CREATE FUNCTION creative_craft_verify_materialization_populate(
  p_challenge_id uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT creative_craft_verify_materialization_challenge(
    $1,'materialization_populate')
$$;
CREATE FUNCTION creative_craft_verify_materialization_forget(
  p_challenge_id uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT creative_craft_verify_materialization_challenge(
    $1,'materialization_forget')
$$;

CREATE FUNCTION creative_craft_materialization_complete_cleanup(
  p_user_id uuid,p_intent_id uuid,p_lease_token uuid,p_receipt_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; attempt_row record; intent_row record;
        proof record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT attempt_id INTO seed FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(seed.attempt_id));
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=seed.attempt_id FOR UPDATE;
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id FOR UPDATE;
  SELECT receipt.*,challenge.materialization_intent_id,
         challenge.target_lease_token,challenge.binding,challenge.evidence
    INTO proof FROM creative_craft_physical_receipts receipt
    JOIN creative_craft_physical_challenges challenge
      ON challenge.user_id=receipt.user_id
     AND challenge.challenge_id=receipt.challenge_id
   WHERE receipt.user_id=p_user_id AND receipt.receipt_id=p_receipt_id
     AND receipt.phase='materialization_forget' FOR SHARE OF receipt,challenge;
  IF intent_row.state='forgotten' THEN
    RETURN proof.receipt_id IS NOT NULL
      AND proof.materialization_intent_id=p_intent_id
      AND proof.target_lease_token=p_lease_token
      AND EXISTS(SELECT 1 FROM creative_craft_physical_receipt_consumptions c
        WHERE c.user_id=p_user_id AND c.receipt_id=p_receipt_id
          AND c.completion_kind='materialization_cleanup');
  END IF;
  IF proof.receipt_id IS NOT NULL
     AND proof.materialization_intent_id=p_intent_id
     AND proof.target_lease_token=p_lease_token
     AND intent_row.state='cleanup_committed'
     AND intent_row.cleanup_lease_token<>p_lease_token THEN
    INSERT INTO creative_craft_physical_receipt_consumptions(
      user_id,receipt_id,completion_kind,attempt_id)
    VALUES(p_user_id,p_receipt_id,'materialization_rejected',
      intent_row.attempt_id) ON CONFLICT DO NOTHING;
    RETURN false;
  END IF;
  IF intent_row.state<>'cleanup_committed'
     OR intent_row.cleanup_lease_token<>p_lease_token
     OR intent_row.cleanup_lease_until<=clock_timestamp()
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR proof.receipt_id IS NULL
     OR proof.materialization_intent_id<>p_intent_id
     OR proof.target_lease_token<>p_lease_token
     OR proof.binding->>'planFenceSha256'<>intent_row.plan_fence_sha256
     OR proof.evidence->>'planSha256'<>intent_row.plan_sha256
     OR EXISTS(SELECT 1 FROM creative_craft_physical_receipt_consumptions c
                WHERE c.user_id=p_user_id AND c.receipt_id=p_receipt_id)
  THEN RETURN false; END IF;
  INSERT INTO creative_craft_physical_receipt_consumptions(
    user_id,receipt_id,completion_kind,attempt_id)
  SELECT receipt.user_id,receipt.receipt_id,'materialization_rejected',
         intent_row.attempt_id
    FROM creative_craft_physical_receipts receipt
    JOIN creative_craft_physical_challenges challenge
      ON challenge.user_id=receipt.user_id
     AND challenge.challenge_id=receipt.challenge_id
   WHERE receipt.user_id=p_user_id
     AND challenge.materialization_intent_id=p_intent_id
     AND receipt.phase IN ('materialization_populate','materialization_forget')
     AND receipt.receipt_id<>p_receipt_id
     AND NOT EXISTS(SELECT 1 FROM creative_craft_physical_receipt_consumptions c
       WHERE c.user_id=receipt.user_id AND c.receipt_id=receipt.receipt_id)
  ON CONFLICT DO NOTHING;
  INSERT INTO creative_craft_physical_receipt_consumptions(
    user_id,receipt_id,completion_kind,attempt_id)
  VALUES(p_user_id,p_receipt_id,'materialization_cleanup',intent_row.attempt_id);
  UPDATE creative_craft_materialization_intents SET state='forgotten',
    cleanup_lease_token=NULL,cleanup_lease_until=NULL,
    forgotten_at=clock_timestamp(),updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND state='cleanup_committed' AND cleanup_lease_token=p_lease_token;
  RETURN FOUND;
END $$;

CREATE UNIQUE INDEX creative_craft_physical_one_materialization_completion
  ON creative_craft_physical_receipt_consumptions
    (user_id,completion_kind,attempt_id)
  WHERE completion_kind IN ('materialization','materialization_cleanup');

ALTER FUNCTION creative_craft_recover_expired_prestart(uuid,uuid,integer)
  RENAME TO creative_craft_recover_expired_prestart_raw114;
CREATE FUNCTION creative_craft_recover_expired_prestart(
  p_user_id uuid,p_attempt_id uuid,p_max_claims integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; intent_row record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  IF p_max_claims<1 OR p_max_claims>10 THEN
    RAISE EXCEPTION 'invalid Craft recovery claim limit' USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id;
  IF intent_row.state IN ('writing','cleanup_running','cleanup_committed') THEN
    RETURN jsonb_build_object(
      'outcome','cleanup_required','terminalStatus','pending');
  END IF;
  IF intent_row.state IN ('attached','legacy_attached') AND NOT EXISTS(
      SELECT 1 FROM creative_craft_launcher_reservations r
       WHERE r.user_id=p_user_id AND r.attempt_id=p_attempt_id
         AND r.materialization_intent_id=intent_row.intent_id) THEN
    RAISE EXCEPTION 'attached materialization lost launcher reservation'
      USING ERRCODE='40001';
  END IF;
  RETURN creative_craft_recover_expired_prestart_raw114(
    p_user_id,p_attempt_id,p_max_claims);
END $$;

CREATE FUNCTION creative_craft_provider_start_requires_materialization()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.provider_started_at IS NOT NULL AND OLD.provider_started_at IS NULL
     AND EXISTS(SELECT 1 FROM creative_execution_steps s
       JOIN creative_execution_jobs j
         ON j.user_id=s.user_id AND j.id=s.job_id
      WHERE s.user_id=NEW.user_id AND s.job_id=NEW.job_id
        AND s.step_id=NEW.step_id AND s.kind='craft'
        AND coalesce((j.graph_snapshot->>'schemaVersion')::integer,1)>=2)
     AND NOT EXISTS(
       SELECT 1 FROM creative_craft_materialization_intents intent
       JOIN creative_craft_launcher_reservations reservation
         ON reservation.user_id=intent.user_id
        AND reservation.materialization_intent_id=intent.intent_id
        AND reservation.attempt_id=intent.attempt_id
      WHERE intent.user_id=NEW.user_id AND intent.attempt_id=NEW.id
        AND intent.state='attached'
        AND reservation.compensation_status='confirmed'
        AND reservation.reserved_at IS NOT NULL
        AND reservation.reservation_receipt=jsonb_build_object(
          'schemaVersion',1,'dispatchId',reservation.dispatch_id::text,
          'requestSha256',reservation.request_sha256,'status','reserved',
          'authoritySha256',reservation.authority_sha256,
          'profileSha256',reservation.profile_sha256)
        AND reservation.reservation_receipt_sha256=
          creative_craft_json_sha256(reservation.reservation_receipt))
  THEN RAISE EXCEPTION 'Craft provider start requires attached materialization'
    USING ERRCODE='55000'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER creative_craft_provider_start_requires_materialization
BEFORE UPDATE OF provider_started_at ON creative_execution_attempts
FOR EACH ROW EXECUTE FUNCTION creative_craft_provider_start_requires_materialization();


-- Generation-scoped population authority.  The intent remains the immutable
-- logical request; every filesystem namespace is an append-only population.
ALTER TABLE creative_craft_physical_installation_bindings
  ADD COLUMN storage_domain_id uuid NOT NULL DEFAULT gen_random_uuid(),
  ADD CONSTRAINT creative_craft_physical_storage_domain_unique
    UNIQUE(storage_domain_id);

ALTER TABLE creative_craft_materialization_intents
  ADD COLUMN logical_plan jsonb,
  ADD COLUMN logical_plan_sha256 text
    CHECK (logical_plan_sha256 ~ '^[0-9a-f]{64}$');
-- This is a one-time upgrade projection of already immutable legacy plans.
-- The 116 guard installed below includes these columns in its immutable tuple.
ALTER TABLE creative_craft_materialization_intents
  DISABLE TRIGGER creative_craft_materialization_intent_guard;
ALTER TABLE creative_craft_materialization_intents
  DISABLE TRIGGER creative_craft_materialization_definer_only;
UPDATE creative_craft_materialization_intents
   SET logical_plan=plan-'namespaceId'-'inputRoot'-'outputRoot',
       logical_plan_sha256=creative_craft_json_sha256(
         plan-'namespaceId'-'inputRoot'-'outputRoot')
 WHERE plan IS NOT NULL;
ALTER TABLE creative_craft_materialization_intents
  ENABLE TRIGGER creative_craft_materialization_intent_guard;
ALTER TABLE creative_craft_materialization_intents
  ENABLE TRIGGER creative_craft_materialization_definer_only;
CREATE FUNCTION creative_craft_materialization_logical_plan_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.logical_plan IS NOT NULL AND
     (OLD.logical_plan,OLD.logical_plan_sha256) IS DISTINCT FROM
     (NEW.logical_plan,NEW.logical_plan_sha256) THEN
    RAISE EXCEPTION 'Craft logical materialization plan is immutable'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER creative_craft_materialization_logical_plan_guard
BEFORE UPDATE ON creative_craft_materialization_intents
FOR EACH ROW EXECUTE FUNCTION creative_craft_materialization_logical_plan_guard();

CREATE TABLE creative_craft_materialization_populations (
  user_id uuid NOT NULL,
  intent_id uuid NOT NULL,
  attempt_id uuid NOT NULL,
  population_generation_id uuid NOT NULL DEFAULT gen_random_uuid(),
  generation_no integer NOT NULL CHECK (generation_no>0),
  population_namespace_id uuid NOT NULL DEFAULT gen_random_uuid(),
  installation_id uuid NOT NULL,
  storage_domain_id uuid NOT NULL,
  state text NOT NULL CHECK (state IN
    ('claimed_unbound','writing','receipt_ready','finalizing','attached',
     'cleanup_required','cleanup_running','cleanup_committed','forgotten',
     'legacy_attached')),
  writer_token uuid,
  writer_lease_until timestamptz,
  writer_consumed_at timestamptz,
  plan jsonb CHECK (plan IS NULL OR jsonb_typeof(plan)='object'),
  plan_sha256 text CHECK (plan_sha256 ~ '^[0-9a-f]{64}$'),
  request_sha256 text CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
  request_authority jsonb CHECK (
    request_authority IS NULL OR jsonb_typeof(request_authority)='object'),
  profile_sha256 text CHECK (profile_sha256 ~ '^[0-9a-f]{64}$'),
  authority_sha256 text CHECK (authority_sha256 ~ '^[0-9a-f]{64}$'),
  population_fence_sha256 text NOT NULL
    CHECK (population_fence_sha256 ~ '^[0-9a-f]{64}$'),
  receipt_id uuid,
  finalize_token uuid,
  finalized_token uuid,
  finalize_lease_until timestamptz,
  finalize_attempt_count integer NOT NULL DEFAULT 0
    CHECK (finalize_attempt_count>=0),
  cleanup_lease_token uuid,
  cleanup_lease_until timestamptz,
  cleanup_attempt_count integer NOT NULL DEFAULT 0
    CHECK (cleanup_attempt_count>=0),
  available_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  bound_at timestamptz,
  receipt_ready_at timestamptz,
  attached_at timestamptz,
  forgotten_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(user_id,population_generation_id),
  UNIQUE(population_generation_id),
  UNIQUE(population_namespace_id),
  UNIQUE(user_id,intent_id,generation_no),
  UNIQUE(user_id,intent_id,attempt_id,population_generation_id),
  FOREIGN KEY(user_id,intent_id,attempt_id)
    REFERENCES creative_craft_materialization_intents(user_id,intent_id,attempt_id),
  FOREIGN KEY(installation_id)
    REFERENCES creative_craft_physical_installation_bindings(installation_id),
  CHECK ((state='claimed_unbound' OR
          (state='forgotten' AND bound_at IS NULL))=(plan IS NULL)),
  CHECK ((plan IS NULL)=(plan_sha256 IS NULL)),
  CHECK ((plan IS NULL)=(request_sha256 IS NULL)),
  CHECK ((plan IS NULL)=(request_authority IS NULL)),
  CHECK ((plan IS NULL)=(profile_sha256 IS NULL)),
  CHECK ((plan IS NULL)=(authority_sha256 IS NULL)),
  CHECK ((state IN ('claimed_unbound','writing'))=
         (writer_lease_until IS NOT NULL)),
  CHECK (state NOT IN ('receipt_ready','finalizing','attached') OR
         receipt_id IS NOT NULL),
  CHECK ((state='finalizing')=(finalize_token IS NOT NULL)),
  CHECK ((state='finalizing')=(finalize_lease_until IS NOT NULL)),
  CHECK ((state IN ('cleanup_running','cleanup_committed'))=
         (cleanup_lease_token IS NOT NULL)),
  CHECK ((state IN ('cleanup_running','cleanup_committed'))=
         (cleanup_lease_until IS NOT NULL)),
  CHECK (state NOT IN ('attached','legacy_attached') OR attached_at IS NOT NULL),
  CHECK ((state='forgotten')=(forgotten_at IS NOT NULL))
);
CREATE UNIQUE INDEX creative_craft_population_one_active
  ON creative_craft_materialization_populations(user_id,intent_id)
  WHERE state IN
    ('claimed_unbound','writing','receipt_ready','finalizing','attached',
     'legacy_attached');
CREATE INDEX creative_craft_population_cleanup
  ON creative_craft_materialization_populations
    (user_id,intent_id,state,available_at,cleanup_lease_until,created_at)
  WHERE state IN
    ('cleanup_required','cleanup_running','cleanup_committed');

INSERT INTO creative_craft_materialization_populations(
  user_id,intent_id,attempt_id,population_generation_id,generation_no,
  population_namespace_id,installation_id,storage_domain_id,state,
  plan,plan_sha256,request_sha256,request_authority,profile_sha256,
  authority_sha256,population_fence_sha256,writer_consumed_at,bound_at,
  attached_at)
SELECT i.user_id,i.intent_id,i.attempt_id,i.namespace_id,1,i.namespace_id,
       i.installation_id,p.storage_domain_id,'legacy_attached',i.plan,
       i.plan_sha256,i.request_sha256,i.request_authority,i.profile_sha256,
       i.authority_sha256,i.plan_fence_sha256,i.attached_at,i.planned_at,
       i.attached_at
  FROM creative_craft_materialization_intents i
  JOIN creative_craft_physical_installation_bindings p
    ON p.installation_id=i.installation_id
 WHERE i.state='legacy_attached';

ALTER TABLE creative_craft_launcher_reservations
  ADD COLUMN materialization_generation_id uuid,
  ADD COLUMN storage_domain_id uuid;
ALTER TABLE creative_craft_launcher_reservations
  DISABLE TRIGGER creative_craft_launcher_reservation_guard;
ALTER TABLE creative_craft_launcher_reservations
  DISABLE TRIGGER creative_craft_reservation_definer_only;
UPDATE creative_craft_launcher_reservations r
   SET materialization_generation_id=p.population_generation_id,
       storage_domain_id=p.storage_domain_id
  FROM creative_craft_materialization_populations p
 WHERE p.user_id=r.user_id AND p.intent_id=r.materialization_intent_id
   AND p.attempt_id=r.attempt_id AND p.state='legacy_attached';
ALTER TABLE creative_craft_launcher_reservations
  ENABLE TRIGGER creative_craft_launcher_reservation_guard;
ALTER TABLE creative_craft_launcher_reservations
  ENABLE TRIGGER creative_craft_reservation_definer_only;
ALTER TABLE creative_craft_launcher_reservations
  ALTER COLUMN materialization_generation_id SET NOT NULL,
  ALTER COLUMN storage_domain_id SET NOT NULL,
  ADD CONSTRAINT creative_craft_launcher_population_fk
    FOREIGN KEY(user_id,materialization_intent_id,attempt_id,
                materialization_generation_id)
    REFERENCES creative_craft_materialization_populations
      (user_id,intent_id,attempt_id,population_generation_id);

ALTER TABLE creative_craft_physical_challenges
  ADD COLUMN materialization_generation_id uuid,
  ADD COLUMN storage_domain_id uuid;
DROP INDEX creative_craft_physical_one_materialization_challenge;
ALTER TABLE creative_craft_physical_challenges
  DROP CONSTRAINT creative_craft_physical_challenges_lease_check,
  DROP CONSTRAINT creative_craft_physical_challenges_intent_check,
  ADD CONSTRAINT creative_craft_physical_challenges_lease_check CHECK (
    (phase IN ('prestart_forget','terminal_forget','adopt_copy',
               'materialization_populate','materialization_forget'))=
      (target_lease_token IS NOT NULL)),
  ADD CONSTRAINT creative_craft_physical_challenges_intent_check CHECK (
    (phase IN ('materialization_populate','materialization_forget'))=
      (materialization_intent_id IS NOT NULL AND
       materialization_generation_id IS NOT NULL AND
       storage_domain_id IS NOT NULL)),
  ADD CONSTRAINT creative_craft_physical_challenges_population_fk
    FOREIGN KEY(user_id,materialization_intent_id,attempt_id,
                materialization_generation_id)
    REFERENCES creative_craft_materialization_populations
      (user_id,intent_id,attempt_id,population_generation_id);
CREATE UNIQUE INDEX creative_craft_physical_one_materialization_challenge
  ON creative_craft_physical_challenges
    (user_id,phase,materialization_intent_id,
     materialization_generation_id,target_lease_token);

ALTER TABLE creative_craft_physical_receipts
  ADD COLUMN storage_domain_id uuid,
  ADD CONSTRAINT creative_craft_physical_receipts_storage_check CHECK (
    (phase IN ('materialization_populate','materialization_forget'))=
      (storage_domain_id IS NOT NULL));
ALTER TABLE creative_craft_physical_receipt_consumptions
  ADD COLUMN materialization_generation_id uuid,
  ADD CONSTRAINT creative_craft_receipt_consumption_generation_check CHECK (
    (completion_kind IN
      ('materialization','materialization_rejected','materialization_cleanup'))=
      (materialization_generation_id IS NOT NULL)),
  ADD CONSTRAINT creative_craft_receipt_consumption_population_fk
    FOREIGN KEY(user_id,materialization_generation_id)
    REFERENCES creative_craft_materialization_populations
      (user_id,population_generation_id);

CREATE OR REPLACE FUNCTION creative_craft_materialization_bind_plan(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_plan jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record; keys text[]; logical_hash text;
        request_body jsonb; request_hash text; logical_authority text;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  SELECT array_agg(key ORDER BY key) INTO keys FROM jsonb_object_keys(p_plan) key;
  IF jsonb_typeof(p_plan)<>'object' OR keys<>ARRAY[
       'controlDocument','dispatchId','expectedOutputs','inputs','limits','profile']::text[]
     OR jsonb_typeof(p_plan->'profile')<>'object'
     OR jsonb_typeof(p_plan->'controlDocument')<>'object'
     OR jsonb_typeof(p_plan->'inputs')<>'array'
     OR jsonb_typeof(p_plan->'expectedOutputs')<>'array'
     OR jsonb_array_length(p_plan->'expectedOutputs')<1
     OR jsonb_typeof(p_plan->'limits')<>'object'
  THEN RAISE EXCEPTION 'logical materialization plan is not closed'
    USING ERRCODE='22023'; END IF;
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
  IF intent_row.intent_id IS NULL OR job_row.status<>'running'
     OR step_row.status<>'running' OR attempt_row.status<>'running'
     OR step_row.kind<>'craft' OR NOT step_row.provider_call
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR attempt_row.claim_lease_token<>intent_row.claim_lease_token
     OR attempt_row.fence_epoch<>intent_row.fence_epoch
     OR attempt_row.lease_until<=clock_timestamp()
     OR p_plan->>'dispatchId'<>intent_row.dispatch_id::text
  THEN RETURN NULL; END IF;
  logical_hash:=creative_craft_json_sha256(p_plan);
  request_body:=jsonb_build_object('schemaVersion',2,
    'dispatchId',intent_row.dispatch_id::text,
    'attempt',jsonb_build_object('ownerUserId',p_user_id::text,
      'jobId',attempt_row.job_id::text,'stepId',attempt_row.step_id::text,
      'attemptId',attempt_row.id::text,'attemptNo',attempt_row.attempt_no,
      'claimLeaseToken',attempt_row.claim_lease_token::text,
      'fenceEpoch',attempt_row.fence_epoch,
      'admissionSha256',attempt_row.admission_sha256,
      'claimSetSha256',attempt_row.claim_set_sha256),
    'authority',jsonb_build_object(
      'jobBindingSha256',attempt_row.craft_job_binding_sha256,
      'preflightSha256',attempt_row.craft_preflight_sha256,
      'adapterPlanSha256',attempt_row.craft_adapter_plan_sha256,
      'capabilityMatrixSha256',attempt_row.craft_capability_matrix_sha256,
      'contractSchemaSha256',attempt_row.craft_contract_schema_sha256,
      'adapterCompilerVersion',attempt_row.craft_adapter_compiler_version,
      'adapterSourceSha256',attempt_row.craft_adapter_source_sha256,
      'recipeSha256',attempt_row.craft_recipe_sha256,
      'inputManifestSha256',attempt_row.craft_resolved_input_manifest_sha256));
  request_hash:=creative_craft_json_sha256(request_body);
  logical_authority:=creative_craft_json_sha256(jsonb_build_object(
    'intentId',intent_row.intent_id::text,'intentNamespaceId',intent_row.namespace_id::text,
    'dispatchId',intent_row.dispatch_id::text,'logicalPlanSha256',logical_hash,
    'requestSha256',request_hash,'requestAuthority',request_body->'authority'));
  IF intent_row.state='writing' THEN
    IF intent_row.logical_plan_sha256<>logical_hash THEN
      RAISE EXCEPTION 'logical materialization plan conflicts with durable intent'
        USING ERRCODE='40001';
    END IF;
  ELSIF intent_row.state='planned' THEN
    UPDATE creative_craft_materialization_intents SET state='writing',
      plan=p_plan,plan_sha256=logical_hash,logical_plan=p_plan,
      logical_plan_sha256=logical_hash,request_sha256=request_hash,
      request_authority=request_body->'authority',
      profile_sha256=creative_craft_json_sha256(p_plan->'profile'),
      authority_sha256=logical_authority,planned_at=clock_timestamp(),
      updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND intent_id=p_intent_id AND state='planned';
  ELSE RETURN NULL; END IF;
  RETURN jsonb_build_object('intentId',intent_row.intent_id::text,
    'intentNamespaceId',intent_row.namespace_id::text,
    'dispatchId',intent_row.dispatch_id::text,'state','writing',
    'intentFenceSha256',intent_row.plan_fence_sha256,
    'logicalPlanSha256',logical_hash,
    'request',jsonb_build_object('body',request_body,'requestSha256',request_hash));
END $$;

CREATE FUNCTION creative_craft_materialization_claim_population(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record; active record; install record;
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
  SELECT installation_id,storage_domain_id INTO install
    FROM creative_craft_physical_installation_bindings;
  IF intent_row.state IN ('attached','legacy_attached') THEN
    RETURN jsonb_build_object('status','attached','intentId',p_intent_id::text);
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
  IF FOUND AND active.state IN ('receipt_ready','finalizing') THEN
    RETURN jsonb_build_object('status',active.state,
      'populationGenerationId',active.population_generation_id::text,
      'receiptId',active.receipt_id::text,
      'storageDomainId',active.storage_domain_id::text,
      'resumeAllowed',false);
  END IF;
  IF FOUND AND active.writer_lease_until>clock_timestamp() THEN
    RETURN jsonb_build_object('status','busy',
      'populationGenerationId',active.population_generation_id::text,
      'storageDomainId',active.storage_domain_id::text);
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

CREATE FUNCTION creative_craft_materialization_bind_population(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_writer_token uuid,
  p_plan jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record; population record; install record;
        keys text[]; plan_hash text; request_body jsonb; request_hash text;
        authority_body jsonb; authority_hash text; profile_hash text;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  SELECT array_agg(key ORDER BY key) INTO keys FROM jsonb_object_keys(p_plan) key;
  IF jsonb_typeof(p_plan)<>'object' OR keys<>ARRAY[
       'controlDocument','dispatchId','expectedOutputs','inputRoot','inputs',
       'limits','namespaceId','outputRoot','profile']::text[]
     OR jsonb_typeof(p_plan->'profile')<>'object'
     OR jsonb_typeof(p_plan->'controlDocument')<>'object'
     OR jsonb_typeof(p_plan->'inputs')<>'array'
     OR jsonb_typeof(p_plan->'expectedOutputs')<>'array'
     OR jsonb_array_length(p_plan->'expectedOutputs')<1
     OR jsonb_typeof(p_plan->'limits')<>'object'
  THEN RAISE EXCEPTION 'population plan is not closed' USING ERRCODE='22023'; END IF;
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
     AND writer_token=p_writer_token FOR UPDATE;
  SELECT installation_id,storage_domain_id INTO install
    FROM creative_craft_physical_installation_bindings;
  IF population.population_generation_id IS NULL OR intent_row.state<>'writing'
     OR population.state NOT IN ('claimed_unbound','writing')
     OR population.writer_lease_until<=clock_timestamp()
     OR population.installation_id<>install.installation_id
     OR population.storage_domain_id<>install.storage_domain_id
     OR job_row.status<>'running' OR step_row.status<>'running'
     OR attempt_row.status<>'running' OR step_row.kind<>'craft'
     OR NOT step_row.provider_call OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR attempt_row.claim_lease_token<>intent_row.claim_lease_token
     OR attempt_row.fence_epoch<>intent_row.fence_epoch
     OR job_row.lease_until<=clock_timestamp()
     OR step_row.lease_until<=clock_timestamp()
     OR attempt_row.lease_until<=clock_timestamp()
     OR job_row.lease_token<>attempt_row.lease_token
     OR step_row.lease_token<>attempt_row.lease_token
  THEN RETURN NULL; END IF;
  IF p_plan->>'dispatchId'<>intent_row.dispatch_id::text
     OR p_plan->>'namespaceId'<>population.population_namespace_id::text
     OR p_plan->>'inputRoot'=p_plan->>'outputRoot'
     OR left(p_plan->>'inputRoot',1)<>'/' OR left(p_plan->>'outputRoot',1)<>'/'
     OR (SELECT count(*) FROM unnest(string_to_array(
           p_plan->>'inputRoot','/')) part
          WHERE part=population.population_namespace_id::text)<>1
     OR (SELECT count(*) FROM unnest(string_to_array(
           p_plan->>'outputRoot','/')) part
          WHERE part=population.population_namespace_id::text)<>1
     OR (p_plan-'namespaceId'-'inputRoot'-'outputRoot')<>intent_row.logical_plan
  THEN RAISE EXCEPTION 'population plan does not match durable generation'
    USING ERRCODE='22023'; END IF;
  plan_hash:=creative_craft_json_sha256(p_plan);
  profile_hash:=creative_craft_json_sha256(p_plan->'profile');
  request_body:=jsonb_build_object('schemaVersion',2,
    'dispatchId',intent_row.dispatch_id::text,
    'attempt',jsonb_build_object('ownerUserId',p_user_id::text,
      'jobId',attempt_row.job_id::text,'stepId',attempt_row.step_id::text,
      'attemptId',attempt_row.id::text,'attemptNo',attempt_row.attempt_no,
      'claimLeaseToken',attempt_row.claim_lease_token::text,
      'fenceEpoch',attempt_row.fence_epoch,
      'admissionSha256',attempt_row.admission_sha256,
      'claimSetSha256',attempt_row.claim_set_sha256),
    'authority',intent_row.request_authority);
  request_hash:=creative_craft_json_sha256(request_body);
  authority_body:=jsonb_build_object(
    'intentId',intent_row.intent_id::text,
    'populationGenerationId',population.population_generation_id::text,
    'populationNamespaceId',population.population_namespace_id::text,
    'storageDomainId',population.storage_domain_id::text,
    'populationFenceSha256',population.population_fence_sha256,
    'dispatchId',intent_row.dispatch_id::text,'requestSha256',request_hash,
    'ownerUserId',p_user_id::text,'attemptId',p_attempt_id::text,
    'requestAuthority',intent_row.request_authority,
    'profileId',p_plan#>>'{profile,profileId}',
    'controlSha256',creative_craft_json_sha256(p_plan->'controlDocument'),
    'inputRoot',p_plan->>'inputRoot','outputRoot',p_plan->>'outputRoot',
    'inputs',p_plan->'inputs','expectedOutputs',p_plan->'expectedOutputs',
    'limits',p_plan->'limits');
  authority_hash:=creative_craft_json_sha256(authority_body);
  IF population.state='writing' THEN
    IF population.plan_sha256<>plan_hash THEN
      RAISE EXCEPTION 'population plan conflicts with durable generation'
        USING ERRCODE='40001';
    END IF;
  ELSE
    UPDATE creative_craft_materialization_populations SET state='writing',
      plan=p_plan,plan_sha256=plan_hash,request_sha256=request_hash,
      request_authority=intent_row.request_authority,
      profile_sha256=profile_hash,authority_sha256=authority_hash,
      bound_at=clock_timestamp(),updated_at=clock_timestamp()
     WHERE user_id=p_user_id
       AND population_generation_id=population.population_generation_id
       AND state='claimed_unbound' AND writer_token=p_writer_token;
  END IF;
  RETURN jsonb_build_object('state','writing',
    'populationGenerationId',population.population_generation_id::text,
    'populationNamespaceId',population.population_namespace_id::text,
    'storageDomainId',population.storage_domain_id::text,
    'populationFenceSha256',population.population_fence_sha256,
    'plan',p_plan,'planSha256',plan_hash,
    'request',jsonb_build_object('body',request_body,'requestSha256',request_hash),
    'authoritySha256',authority_hash,'profileSha256',profile_hash);
END $$;

CREATE FUNCTION creative_craft_materialization_release_population(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_writer_token uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE seed record; population record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  PERFORM 1 FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT job_id,step_id INTO seed FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id;
  PERFORM 1 FROM creative_execution_jobs
   WHERE user_id=p_user_id AND id=seed.job_id FOR UPDATE;
  PERFORM 1 FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=seed.job_id AND step_id=seed.step_id FOR UPDATE;
  PERFORM 1 FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  PERFORM 1 FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND attempt_id=p_attempt_id
   FOR UPDATE;
  SELECT * INTO population FROM creative_craft_materialization_populations
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND attempt_id=p_attempt_id
     AND writer_token=p_writer_token FOR UPDATE;
  IF population.state='claimed_unbound' THEN
    UPDATE creative_craft_materialization_populations SET state='forgotten',
      writer_lease_until=NULL,forgotten_at=clock_timestamp(),
      updated_at=clock_timestamp()
     WHERE user_id=p_user_id
       AND population_generation_id=population.population_generation_id;
    RETURN true;
  ELSIF population.state='writing' THEN
    UPDATE creative_craft_materialization_populations
       SET state='cleanup_required',writer_lease_until=NULL,
           available_at=clock_timestamp(),updated_at=clock_timestamp()
     WHERE user_id=p_user_id
       AND population_generation_id=population.population_generation_id;
    RETURN true;
  END IF;
  RETURN false;
END $$;

DROP FUNCTION creative_craft_issue_materialization_populate_challenge(uuid,uuid,uuid);
CREATE FUNCTION creative_craft_issue_materialization_populate_challenge(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,
  p_generation_id uuid,p_writer_token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record; population record;
        install record; challenge uuid:=gen_random_uuid(); receipt uuid:=gen_random_uuid();
        binding jsonb; evidence jsonb; stored record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR owner_row.deletion_requested_at IS NOT NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT job_id,step_id INTO seed FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id;
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
  SELECT installation_id,storage_domain_id,verifier_policy_sha256 INTO install
    FROM creative_craft_physical_installation_bindings;
  IF population.state<>'writing' OR population.writer_token<>p_writer_token
     OR population.writer_lease_until<=clock_timestamp()
     OR population.installation_id<>install.installation_id
     OR population.storage_domain_id<>install.storage_domain_id
     OR job_row.status<>'running' OR step_row.status<>'running'
     OR attempt_row.status<>'running' OR step_row.kind<>'craft'
     OR NOT step_row.provider_call
     OR job_row.lease_until<=clock_timestamp()
     OR step_row.lease_until<=clock_timestamp()
     OR job_row.lease_token<>attempt_row.lease_token
     OR step_row.lease_token<>attempt_row.lease_token
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR attempt_row.claim_lease_token<>intent_row.claim_lease_token
     OR attempt_row.fence_epoch<>intent_row.fence_epoch
     OR attempt_row.lease_until<=clock_timestamp()
  THEN RETURN NULL; END IF;
  binding:=jsonb_build_object('installationId',install.installation_id::text,
    'storageDomainId',install.storage_domain_id::text,
    'verifierPolicySha256',install.verifier_policy_sha256,
    'ownerUserId',p_user_id::text,'jobId',attempt_row.job_id::text,
    'stepId',attempt_row.step_id::text,'attemptId',attempt_row.id::text,
    'attemptNo',attempt_row.attempt_no,
    'claimLeaseTokenSha256',creative_craft_text_sha256(attempt_row.claim_lease_token::text),
    'fenceEpoch',attempt_row.fence_epoch,
    'admissionSha256',attempt_row.admission_sha256,
    'claimSetSha256',attempt_row.claim_set_sha256,
    'intentId',intent_row.intent_id::text,
    'populationGenerationId',population.population_generation_id::text,
    'namespaceId',population.population_namespace_id::text,
    'dispatchId',intent_row.dispatch_id::text,
    'requestSha256',population.request_sha256,
    'authoritySha256',population.authority_sha256,
    'populationFenceSha256',population.population_fence_sha256);
  evidence:=jsonb_build_object('planSha256',population.plan_sha256,
    'materializationSha256',creative_craft_json_sha256(jsonb_build_object(
      'inputRoot',population.plan->>'inputRoot','outputRoot',population.plan->>'outputRoot',
      'inputs',population.plan->'inputs','expectedOutputs',population.plan->'expectedOutputs',
      'limits',population.plan->'limits')),
    'inputTreeSha256',creative_craft_json_sha256(population.plan->'inputs'),
    'outputTreeSha256',creative_craft_json_sha256(population.plan->'expectedOutputs'),
    'ownershipMarkerSha256',creative_craft_json_sha256(jsonb_build_object(
      'ownerUserId',p_user_id::text,'attemptId',p_attempt_id::text,
      'intentId',p_intent_id::text,
      'populationGenerationId',p_generation_id::text,
      'namespaceId',population.population_namespace_id::text,
      'storageDomainId',population.storage_domain_id::text)));
  INSERT INTO creative_craft_physical_challenges(
    user_id,challenge_id,receipt_id,installation_id,phase,attempt_id,
    target_lease_token,materialization_intent_id,materialization_generation_id,
    storage_domain_id,binding,evidence,verifier_proof,issued_role)
  VALUES(p_user_id,challenge,receipt,install.installation_id,
    'materialization_populate',p_attempt_id,p_writer_token,p_intent_id,
    p_generation_id,install.storage_domain_id,binding,evidence,
    jsonb_build_object('plan',population.plan,
      'populationFenceSha256',population.population_fence_sha256),
    current_setting('role',true))
  ON CONFLICT DO NOTHING;
  SELECT * INTO stored FROM creative_craft_physical_challenges
   WHERE user_id=p_user_id AND phase='materialization_populate'
     AND materialization_intent_id=p_intent_id
     AND materialization_generation_id=p_generation_id
     AND target_lease_token=p_writer_token;
  RETURN jsonb_build_object('challengeId',stored.challenge_id::text,
    'receiptId',stored.receipt_id::text,'phase',stored.phase,
    'binding',stored.binding,'evidence',stored.evidence,
    'proof',stored.verifier_proof);
END $$;

CREATE FUNCTION creative_craft_materialization_claim_finalize(
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
  IF population.receipt_id<>p_receipt_id
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
      'storageDomainId',population.storage_domain_id::text);
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

CREATE FUNCTION creative_craft_materialization_release_finalize(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_generation_id uuid,
  p_receipt_id uuid,p_finalize_token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE seed record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  PERFORM 1 FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT job_id,step_id INTO seed FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id;
  PERFORM 1 FROM creative_execution_jobs WHERE user_id=p_user_id AND id=seed.job_id FOR UPDATE;
  PERFORM 1 FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=seed.job_id AND step_id=seed.step_id FOR UPDATE;
  PERFORM 1 FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=p_attempt_id FOR UPDATE;
  PERFORM 1 FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND attempt_id=p_attempt_id FOR UPDATE;
  UPDATE creative_craft_materialization_populations SET state='receipt_ready',
    finalize_token=NULL,finalize_lease_until=NULL,updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND attempt_id=p_attempt_id
     AND population_generation_id=p_generation_id AND receipt_id=p_receipt_id
     AND state='finalizing' AND finalize_token=p_finalize_token;
  RETURN FOUND;
END $$;

DROP FUNCTION creative_craft_materialization_finalize(uuid,uuid,uuid,uuid);
CREATE FUNCTION creative_craft_materialization_finalize(
  p_user_id uuid,p_attempt_id uuid,p_intent_id uuid,p_generation_id uuid,
  p_receipt_id uuid,p_finalize_token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; job_row record; step_row record;
        attempt_row record; intent_row record; population record; proof record;
        inserted integer; stored record;
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
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND attempt_id=p_attempt_id FOR UPDATE;
  SELECT * INTO population FROM creative_craft_materialization_populations
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND attempt_id=p_attempt_id
     AND population_generation_id=p_generation_id FOR UPDATE;
  SELECT receipt.*,challenge.materialization_intent_id,
         challenge.materialization_generation_id,challenge.attempt_id,
         challenge.target_lease_token,challenge.storage_domain_id,
         challenge.binding,challenge.evidence INTO proof
    FROM creative_craft_physical_receipts receipt
    JOIN creative_craft_physical_challenges challenge
      ON challenge.user_id=receipt.user_id AND challenge.challenge_id=receipt.challenge_id
   WHERE receipt.user_id=p_user_id AND receipt.receipt_id=p_receipt_id
     AND receipt.phase='materialization_populate' FOR SHARE OF receipt,challenge;
  IF population.state='attached' AND intent_row.state='attached' THEN
    IF population.receipt_id<>p_receipt_id
       OR population.finalized_token IS DISTINCT FROM p_finalize_token
       OR proof.receipt_id IS NULL
       OR NOT EXISTS(SELECT 1 FROM creative_craft_physical_receipt_consumptions c
          WHERE c.user_id=p_user_id AND c.receipt_id=p_receipt_id
            AND c.attempt_id=p_attempt_id AND c.completion_kind='materialization'
            AND c.materialization_generation_id=p_generation_id) THEN RETURN NULL; END IF;
    SELECT * INTO stored FROM creative_craft_launcher_reservations
     WHERE user_id=p_user_id AND attempt_id=p_attempt_id
       AND materialization_generation_id=p_generation_id;
    RETURN jsonb_build_object('created',false,'intentId',p_intent_id::text,
      'populationGenerationId',p_generation_id::text,'state','attached',
      'request',jsonb_build_object('body',jsonb_build_object('schemaVersion',2,
        'dispatchId',stored.dispatch_id::text,'attempt',jsonb_build_object(
          'ownerUserId',stored.user_id::text,'jobId',stored.job_id::text,
          'stepId',stored.step_id::text,'attemptId',stored.attempt_id::text,
          'attemptNo',stored.attempt_no,'claimLeaseToken',stored.claim_lease_token::text,
          'fenceEpoch',stored.fence_epoch,'admissionSha256',stored.admission_sha256,
          'claimSetSha256',stored.claim_set_sha256),'authority',stored.request_authority),
        'requestSha256',stored.request_sha256),
      'authoritySha256',stored.authority_sha256,'profileSha256',stored.profile_sha256);
  END IF;
  IF population.state<>'finalizing' OR population.finalize_token<>p_finalize_token
     OR population.finalize_lease_until<=clock_timestamp()
     OR population.receipt_id<>p_receipt_id OR intent_row.state<>'writing'
     OR job_row.status<>'running' OR step_row.status<>'running'
     OR attempt_row.status<>'running' OR step_row.kind<>'craft' OR NOT step_row.provider_call
     OR job_row.lease_until<=clock_timestamp()
     OR step_row.lease_until<=clock_timestamp()
     OR attempt_row.lease_until<=clock_timestamp()
     OR job_row.lease_token<>attempt_row.lease_token
     OR step_row.lease_token<>attempt_row.lease_token
     OR attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR attempt_row.claim_lease_token<>intent_row.claim_lease_token
     OR attempt_row.fence_epoch<>intent_row.fence_epoch
     OR proof.receipt_id IS NULL OR proof.materialization_intent_id<>p_intent_id
     OR proof.materialization_generation_id<>p_generation_id
     OR proof.target_lease_token<>population.writer_token
     OR proof.storage_domain_id<>population.storage_domain_id
     OR proof.binding->>'populationFenceSha256'<>population.population_fence_sha256
     OR proof.evidence->>'planSha256'<>population.plan_sha256
     OR EXISTS(SELECT 1 FROM creative_craft_physical_receipt_consumptions c
                WHERE c.user_id=p_user_id AND c.receipt_id=p_receipt_id)
  THEN RETURN NULL; END IF;
  INSERT INTO creative_craft_launcher_reservations(
    user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,fence_epoch,
    admission_id,admission_sha256,claim_set_sha256,dispatch_id,request_sha256,
    request_authority,profile_id,profile_sha256,control_document,input_root,
    output_root,inputs,expected_outputs,limits,authority_sha256,
    materialization_intent_id,materialization_generation_id,storage_domain_id)
  VALUES(p_user_id,p_attempt_id,intent_row.job_id,intent_row.step_id,
    intent_row.attempt_no,intent_row.claim_lease_token,intent_row.fence_epoch,
    intent_row.admission_id,intent_row.admission_sha256,intent_row.claim_set_sha256,
    intent_row.dispatch_id,population.request_sha256,population.request_authority,
    population.plan#>>'{profile,profileId}',population.profile_sha256,
    population.plan->'controlDocument',population.plan->>'inputRoot',
    population.plan->>'outputRoot',population.plan->'inputs',
    population.plan->'expectedOutputs',population.plan->'limits',
    population.authority_sha256,p_intent_id,p_generation_id,
    population.storage_domain_id)
  ON CONFLICT(user_id,attempt_id) DO NOTHING;
  GET DIAGNOSTICS inserted=ROW_COUNT;
  SELECT * INTO stored FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id FOR SHARE;
  IF stored.materialization_intent_id<>p_intent_id
     OR stored.materialization_generation_id<>p_generation_id
     OR stored.storage_domain_id<>population.storage_domain_id
     OR stored.request_sha256<>population.request_sha256
     OR stored.authority_sha256<>population.authority_sha256
  THEN RAISE EXCEPTION 'launcher reservation conflicts with population generation'
    USING ERRCODE='40001'; END IF;
  INSERT INTO creative_craft_physical_receipt_consumptions(
    user_id,receipt_id,completion_kind,attempt_id,materialization_generation_id)
  VALUES(p_user_id,p_receipt_id,'materialization',p_attempt_id,p_generation_id);
  UPDATE creative_craft_materialization_populations SET state='attached',
    finalized_token=p_finalize_token,finalize_token=NULL,
    finalize_lease_until=NULL,attached_at=clock_timestamp(),
    updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND population_generation_id=p_generation_id
     AND state='finalizing' AND finalize_token=p_finalize_token;
  UPDATE creative_craft_materialization_intents SET state='attached',
    attached_at=clock_timestamp(),updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND intent_id=p_intent_id AND state='writing';
  RETURN jsonb_build_object('created',inserted=1,'intentId',p_intent_id::text,
    'populationGenerationId',p_generation_id::text,'state','attached',
    'request',jsonb_build_object('body',jsonb_build_object('schemaVersion',2,
      'dispatchId',stored.dispatch_id::text,'attempt',jsonb_build_object(
        'ownerUserId',stored.user_id::text,'jobId',stored.job_id::text,
        'stepId',stored.step_id::text,'attemptId',stored.attempt_id::text,
        'attemptNo',stored.attempt_no,'claimLeaseToken',stored.claim_lease_token::text,
        'fenceEpoch',stored.fence_epoch,'admissionSha256',stored.admission_sha256,
        'claimSetSha256',stored.claim_set_sha256),'authority',stored.request_authority),
      'requestSha256',stored.request_sha256),
    'authoritySha256',stored.authority_sha256,'profileSha256',stored.profile_sha256);
END $$;

CREATE FUNCTION creative_craft_accept_materialization_receipt(
  p_challenge_id uuid,p_phase text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE challenge record; prior record; owner_row record; seed record;
        job_row record; step_row record; attempt_row record;
        intent_row record; population record; current_fence boolean:=false;
        body jsonb; observed timestamptz; receipt_hash text; changed integer;
        reservation_row record; ack_row record; cleanup_authorized boolean;
BEGIN
  PERFORM creative_craft_require_role('launcher_verifier');
  IF p_phase NOT IN ('materialization_populate','materialization_forget') THEN
    RAISE EXCEPTION 'invalid materialization verification phase' USING ERRCODE='22023';
  END IF;
  SELECT * INTO challenge FROM creative_craft_physical_challenges
   WHERE challenge_id=p_challenge_id AND phase=p_phase;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(challenge.user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=challenge.user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR (p_phase='materialization_populate'
                    AND owner_row.deletion_requested_at IS NOT NULL)
  THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(challenge.attempt_id));
  SELECT job_id,step_id INTO seed FROM creative_execution_attempts
   WHERE user_id=challenge.user_id AND id=challenge.attempt_id;
  SELECT * INTO job_row FROM creative_execution_jobs
   WHERE user_id=challenge.user_id AND id=seed.job_id FOR KEY SHARE;
  SELECT * INTO step_row FROM creative_execution_steps
   WHERE user_id=challenge.user_id AND job_id=seed.job_id
     AND step_id=seed.step_id FOR KEY SHARE;
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=challenge.user_id AND id=challenge.attempt_id FOR KEY SHARE;
  SELECT * INTO reservation_row FROM creative_craft_launcher_reservations
   WHERE user_id=challenge.user_id AND attempt_id=challenge.attempt_id FOR KEY SHARE;
  SELECT * INTO ack_row FROM creative_craft_launcher_ack_outbox
   WHERE user_id=challenge.user_id
     AND source_attempt_id=challenge.attempt_id FOR KEY SHARE;
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=challenge.user_id AND intent_id=challenge.materialization_intent_id
     AND attempt_id=challenge.attempt_id;
  SELECT * INTO population FROM creative_craft_materialization_populations
   WHERE user_id=challenge.user_id
     AND population_generation_id=challenge.materialization_generation_id
     AND intent_id=challenge.materialization_intent_id
     AND attempt_id=challenge.attempt_id FOR UPDATE;
  SELECT * INTO challenge FROM creative_craft_physical_challenges
   WHERE challenge_id=p_challenge_id AND phase=p_phase FOR KEY SHARE;
  IF p_phase='materialization_populate' THEN
    SELECT * INTO prior FROM creative_craft_physical_receipts
     WHERE user_id=challenge.user_id AND challenge_id=challenge.challenge_id
       AND phase=challenge.phase AND storage_domain_id=population.storage_domain_id;
    IF FOUND AND population.state IN ('receipt_ready','finalizing','attached')
       AND population.receipt_id=prior.receipt_id
       AND population.writer_token=challenge.target_lease_token
       AND population.storage_domain_id=challenge.storage_domain_id
       AND challenge.binding->>'populationGenerationId'=
             population.population_generation_id::text
       AND challenge.binding->>'populationFenceSha256'=
             population.population_fence_sha256 THEN
      RETURN jsonb_build_object('body',prior.body,
        'receiptSha256',prior.receipt_sha256,
        'observedAt',to_char(prior.observed_at AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
    END IF;
    current_fence:=population.state='writing'
      AND population.writer_token=challenge.target_lease_token
      AND population.writer_lease_until>clock_timestamp()
      AND population.storage_domain_id=challenge.storage_domain_id
      AND job_row.status='running' AND step_row.status='running'
      AND attempt_row.status='running'
      AND job_row.lease_until>clock_timestamp()
      AND step_row.lease_until>clock_timestamp()
      AND attempt_row.lease_until>clock_timestamp()
      AND job_row.lease_token=attempt_row.lease_token
      AND step_row.lease_token=attempt_row.lease_token
      AND attempt_row.provider_started_at IS NULL
      AND attempt_row.provider_returned_at IS NULL
      AND attempt_row.claim_lease_token=intent_row.claim_lease_token
      AND attempt_row.fence_epoch=intent_row.fence_epoch
      AND challenge.binding->>'populationGenerationId'=
            population.population_generation_id::text
      AND challenge.binding->>'populationFenceSha256'=
            population.population_fence_sha256
      AND challenge.evidence->>'planSha256'=population.plan_sha256;
  ELSE
    SELECT * INTO prior FROM creative_craft_physical_receipts
     WHERE user_id=challenge.user_id AND challenge_id=challenge.challenge_id
       AND phase=challenge.phase AND storage_domain_id=population.storage_domain_id;
    IF FOUND THEN RETURN jsonb_build_object('body',prior.body,
      'receiptSha256',prior.receipt_sha256,
      'observedAt',to_char(prior.observed_at AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')); END IF;
    cleanup_authorized:=population.attached_at IS NULL OR
      (attempt_row.provider_started_at IS NULL AND
        attempt_row.provider_returned_at IS NULL) OR
      (reservation_row.materialization_intent_id=
         challenge.materialization_intent_id AND
       reservation_row.materialization_generation_id=
         population.population_generation_id AND
       reservation_row.storage_domain_id=population.storage_domain_id AND
       (reservation_row.compensation_status='compensated' OR
        ack_row.status='done'));
    current_fence:=population.state='cleanup_committed'
      AND coalesce(cleanup_authorized,false)
      AND population.cleanup_lease_token=challenge.target_lease_token
      AND population.cleanup_lease_until>clock_timestamp()
      AND population.storage_domain_id=challenge.storage_domain_id
      AND challenge.binding->>'populationGenerationId'=
            population.population_generation_id::text
      AND challenge.binding->>'populationFenceSha256'=
            population.population_fence_sha256
      AND challenge.evidence->>'planSha256'=population.plan_sha256;
  END IF;
  IF NOT coalesce(current_fence,false) THEN RETURN NULL; END IF;
  body:=jsonb_build_object('schemaVersion',2,
    'receiptId',challenge.receipt_id::text,'challengeId',challenge.challenge_id::text,
    'phase',challenge.phase,'binding',challenge.binding,'evidence',challenge.evidence);
  receipt_hash:=creative_craft_json_sha256(body); observed:=clock_timestamp();
  INSERT INTO creative_craft_physical_receipts(
    user_id,receipt_id,challenge_id,installation_id,phase,body,
    receipt_sha256,observed_at,verifier_role,storage_domain_id)
  VALUES(challenge.user_id,challenge.receipt_id,challenge.challenge_id,
    challenge.installation_id,challenge.phase,body,receipt_hash,observed,
    current_setting('role',true),challenge.storage_domain_id) ON CONFLICT DO NOTHING;
  IF p_phase='materialization_populate' THEN
    UPDATE creative_craft_materialization_populations
       SET state='receipt_ready',receipt_id=challenge.receipt_id,
           writer_lease_until=NULL,writer_consumed_at=clock_timestamp(),
           receipt_ready_at=clock_timestamp(),updated_at=clock_timestamp()
     WHERE user_id=challenge.user_id
       AND population_generation_id=challenge.materialization_generation_id
       AND state='writing' AND writer_token=challenge.target_lease_token
       AND writer_lease_until>clock_timestamp()
       AND storage_domain_id=challenge.storage_domain_id;
    GET DIAGNOSTICS changed=ROW_COUNT;
    IF changed<>1 THEN
      RAISE EXCEPTION 'population receipt lost its exact writer fence'
        USING ERRCODE='40001';
    END IF;
  END IF;
  SELECT * INTO prior FROM creative_craft_physical_receipts
   WHERE user_id=challenge.user_id AND challenge_id=challenge.challenge_id
     AND phase=challenge.phase AND storage_domain_id=challenge.storage_domain_id;
  RETURN jsonb_build_object('body',prior.body,'receiptSha256',prior.receipt_sha256,
    'observedAt',to_char(prior.observed_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
END $$;

-- The verifier can inspect evidence, but only the completion definer owns the
-- receipt+population CAS.  A failed population CAS rolls the receipt INSERT
-- back in the same transaction, so no verifier role receives table UPDATE.
CREATE OR REPLACE FUNCTION creative_craft_verify_materialization_challenge(
  p_challenge_id uuid,p_phase text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  PERFORM creative_craft_require_role('launcher_verifier');
  RETURN creative_craft_accept_materialization_receipt(
    p_challenge_id,p_phase);
END $$;

DROP INDEX creative_craft_physical_one_materialization_completion;
CREATE UNIQUE INDEX creative_craft_physical_one_population_attachment
  ON creative_craft_physical_receipt_consumptions(user_id,attempt_id)
  WHERE completion_kind='materialization';
CREATE UNIQUE INDEX creative_craft_physical_one_population_cleanup
  ON creative_craft_physical_receipt_consumptions
    (user_id,materialization_generation_id)
  WHERE completion_kind='materialization_cleanup';

CREATE OR REPLACE FUNCTION creative_craft_materialization_claim_cleanup(
  p_user_id uuid,p_intent_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; attempt_row record; intent_row record;
        job_row record; step_row record; population record;
        token uuid:=gen_random_uuid(); until_at timestamptz;
        deletion_cleanup boolean; execution_expired boolean;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT attempt_id,job_id,step_id INTO seed FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(seed.attempt_id));
  SELECT * INTO job_row FROM creative_execution_jobs
   WHERE user_id=p_user_id AND id=seed.job_id FOR UPDATE;
  SELECT * INTO step_row FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=seed.job_id AND step_id=seed.step_id FOR UPDATE;
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=seed.attempt_id FOR UPDATE;
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id FOR UPDATE;
  deletion_cleanup:=owner_row.deletion_requested_at IS NOT NULL;
  execution_expired:=job_row.status='running' AND step_row.status='running'
    AND attempt_row.status='running' AND step_row.kind='craft' AND step_row.provider_call
    AND job_row.lease_until<=clock_timestamp()
    AND step_row.lease_until<=clock_timestamp()
    AND attempt_row.lease_until<=clock_timestamp()
    AND attempt_row.provider_started_at IS NULL
    AND attempt_row.provider_returned_at IS NULL;
  SELECT * INTO population FROM creative_craft_materialization_populations
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND ((state='cleanup_required' AND available_at<=clock_timestamp()) OR
          (state IN ('cleanup_running','cleanup_committed') AND
           cleanup_lease_until<=clock_timestamp()))
   ORDER BY CASE state WHEN 'cleanup_committed' THEN 0
                       WHEN 'cleanup_running' THEN 1 ELSE 2 END,
            generation_no
   FOR UPDATE LIMIT 1;
  IF NOT FOUND AND (attempt_row.provider_started_at IS NOT NULL
     OR attempt_row.provider_returned_at IS NOT NULL
     OR (NOT deletion_cleanup AND NOT execution_expired))
  THEN RETURN NULL; END IF;
  IF NOT FOUND THEN
    SELECT * INTO population FROM creative_craft_materialization_populations
     WHERE user_id=p_user_id AND intent_id=p_intent_id
       AND state IN ('claimed_unbound','writing','receipt_ready','finalizing')
     ORDER BY generation_no FOR UPDATE LIMIT 1;
    IF FOUND THEN
      IF population.state='finalizing'
         AND population.finalize_lease_until>clock_timestamp() THEN RETURN NULL; END IF;
      IF population.state='claimed_unbound' THEN
        UPDATE creative_craft_materialization_populations SET state='forgotten',
          writer_lease_until=NULL,forgotten_at=clock_timestamp(),updated_at=clock_timestamp()
         WHERE user_id=p_user_id
           AND population_generation_id=population.population_generation_id;
        IF NOT EXISTS(SELECT 1
            FROM creative_craft_materialization_populations remaining
           WHERE remaining.user_id=p_user_id
             AND remaining.intent_id=p_intent_id
             AND remaining.state<>'forgotten') THEN
          UPDATE creative_craft_materialization_intents SET state='forgotten',
            forgotten_at=clock_timestamp(),updated_at=clock_timestamp()
           WHERE user_id=p_user_id AND intent_id=p_intent_id
             AND state='writing';
        END IF;
        RETURN jsonb_build_object('intentId',p_intent_id::text,
          'populationGenerationId',population.population_generation_id::text,
          'state','forgotten','physicalRequired',false);
      END IF;
      IF population.receipt_id IS NOT NULL THEN
        INSERT INTO creative_craft_physical_receipt_consumptions(
          user_id,receipt_id,completion_kind,attempt_id,
          materialization_generation_id)
        VALUES(p_user_id,population.receipt_id,'materialization_rejected',
          seed.attempt_id,population.population_generation_id)
        ON CONFLICT DO NOTHING;
      END IF;
      UPDATE creative_craft_materialization_populations
         SET state='cleanup_required',writer_lease_until=NULL,
             finalize_token=NULL,finalize_lease_until=NULL,
             available_at=clock_timestamp(),updated_at=clock_timestamp()
       WHERE user_id=p_user_id
         AND population_generation_id=population.population_generation_id;
      SELECT * INTO population FROM creative_craft_materialization_populations
       WHERE user_id=p_user_id
         AND population_generation_id=population.population_generation_id FOR UPDATE;
    END IF;
  END IF;
  IF NOT FOUND THEN
    IF intent_row.state IN ('planned','writing') THEN
      UPDATE creative_craft_materialization_intents SET state='forgotten',
        forgotten_at=clock_timestamp(),updated_at=clock_timestamp()
       WHERE user_id=p_user_id AND intent_id=p_intent_id
         AND state IN ('planned','writing');
      RETURN jsonb_build_object('intentId',p_intent_id::text,'state','forgotten',
        'physicalRequired',false);
    END IF;
    RETURN NULL;
  END IF;
  IF population.state IN ('cleanup_running','cleanup_committed') THEN
    INSERT INTO creative_craft_physical_receipt_consumptions(
      user_id,receipt_id,completion_kind,attempt_id,
      materialization_generation_id)
    SELECT receipt.user_id,receipt.receipt_id,'materialization_rejected',
           seed.attempt_id,population.population_generation_id
      FROM creative_craft_physical_receipts receipt
      JOIN creative_craft_physical_challenges challenge
        ON challenge.user_id=receipt.user_id
       AND challenge.challenge_id=receipt.challenge_id
     WHERE receipt.user_id=p_user_id
       AND receipt.phase='materialization_forget'
       AND challenge.materialization_intent_id=p_intent_id
       AND challenge.materialization_generation_id=
           population.population_generation_id
       AND challenge.target_lease_token=population.cleanup_lease_token
       AND NOT EXISTS(SELECT 1
         FROM creative_craft_physical_receipt_consumptions consumed
        WHERE consumed.user_id=receipt.user_id
          AND consumed.receipt_id=receipt.receipt_id)
    ON CONFLICT DO NOTHING;
  END IF;
  until_at:=clock_timestamp()+interval '2 minutes';
  UPDATE creative_craft_materialization_populations
   SET state=CASE WHEN population.state='cleanup_committed'
                  THEN 'cleanup_committed' ELSE 'cleanup_running' END,
    cleanup_lease_token=token,cleanup_lease_until=until_at,
    cleanup_attempt_count=cleanup_attempt_count+1,updated_at=clock_timestamp()
   WHERE user_id=p_user_id
     AND population_generation_id=population.population_generation_id;
  RETURN jsonb_build_object('intentId',p_intent_id::text,
    'populationGenerationId',population.population_generation_id::text,
    'populationNamespaceId',population.population_namespace_id::text,
    'storageDomainId',population.storage_domain_id::text,
    'state',CASE WHEN population.state='cleanup_committed'
                 THEN 'cleanup_committed' ELSE 'cleanup_running' END,
    'physicalRequired',true,
    'cleanupLeaseToken',token::text,
    'cleanupLeaseUntil',to_char(until_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'plan',population.plan,'planSha256',population.plan_sha256,
    'populationFenceSha256',population.population_fence_sha256);
END $$;

CREATE OR REPLACE FUNCTION creative_craft_materialization_commit_cleanup(
  p_user_id uuid,p_intent_id uuid,p_lease_token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; attempt_row record; population record;
        install record; reservation_row record; ack_row record;
        cleanup_authorized boolean;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT attempt_id,job_id,step_id INTO seed FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(seed.attempt_id));
  PERFORM 1 FROM creative_execution_jobs WHERE user_id=p_user_id AND id=seed.job_id FOR UPDATE;
  PERFORM 1 FROM creative_execution_steps
   WHERE user_id=p_user_id AND job_id=seed.job_id AND step_id=seed.step_id FOR UPDATE;
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=seed.attempt_id FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT * INTO reservation_row FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=seed.attempt_id FOR UPDATE;
  SELECT * INTO ack_row FROM creative_craft_launcher_ack_outbox
   WHERE user_id=p_user_id AND source_attempt_id=seed.attempt_id FOR UPDATE;
  PERFORM 1 FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id FOR UPDATE;
  SELECT * INTO population FROM creative_craft_materialization_populations
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND cleanup_lease_token=p_lease_token FOR UPDATE;
  SELECT storage_domain_id INTO install FROM creative_craft_physical_installation_bindings;
  IF population.storage_domain_id<>install.storage_domain_id THEN RETURN false; END IF;
  cleanup_authorized:=population.attached_at IS NULL OR
    (attempt_row.provider_started_at IS NULL AND
      attempt_row.provider_returned_at IS NULL) OR
    (reservation_row.materialization_intent_id=p_intent_id AND
     reservation_row.materialization_generation_id=
       population.population_generation_id AND
     reservation_row.storage_domain_id=population.storage_domain_id AND
     (reservation_row.compensation_status='compensated' OR
      ack_row.status='done'));
  IF NOT coalesce(cleanup_authorized,false) THEN RETURN false; END IF;
  IF population.state='cleanup_committed' THEN RETURN true; END IF;
  UPDATE creative_craft_materialization_populations SET state='cleanup_committed',
    updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND state='cleanup_running' AND cleanup_lease_token=p_lease_token
     AND cleanup_lease_until>clock_timestamp();
  RETURN FOUND;
END $$;

CREATE OR REPLACE FUNCTION creative_craft_materialization_release_cleanup(
  p_user_id uuid,p_intent_id uuid,p_lease_token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE seed record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  PERFORM 1 FROM users WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT attempt_id INTO seed FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(seed.attempt_id));
  UPDATE creative_craft_materialization_populations
     SET state='cleanup_required',cleanup_lease_token=NULL,
         cleanup_lease_until=NULL,available_at=clock_timestamp()+interval '1 second',
         updated_at=clock_timestamp()
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND state='cleanup_running' AND cleanup_lease_token=p_lease_token;
  RETURN FOUND;
END $$;

CREATE OR REPLACE FUNCTION creative_craft_issue_materialization_forget_challenge(
  p_user_id uuid,p_intent_id uuid,p_lease_token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; attempt_row record; intent_row record;
        population record; install record; challenge uuid:=gen_random_uuid();
        receipt uuid:=gen_random_uuid(); binding jsonb; evidence jsonb; stored record;
        reservation_row record; ack_row record; cleanup_authorized boolean;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT attempt_id INTO seed FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(seed.attempt_id));
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=seed.attempt_id FOR UPDATE;
  SELECT * INTO reservation_row FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=seed.attempt_id FOR UPDATE;
  SELECT * INTO ack_row FROM creative_craft_launcher_ack_outbox
   WHERE user_id=p_user_id AND source_attempt_id=seed.attempt_id FOR UPDATE;
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id FOR UPDATE;
  SELECT * INTO population FROM creative_craft_materialization_populations
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND cleanup_lease_token=p_lease_token FOR UPDATE;
  SELECT installation_id,storage_domain_id,verifier_policy_sha256 INTO install
    FROM creative_craft_physical_installation_bindings;
  IF population.state<>'cleanup_committed'
     OR population.cleanup_lease_until<=clock_timestamp()
     OR population.storage_domain_id<>install.storage_domain_id
  THEN RETURN NULL; END IF;
  cleanup_authorized:=population.attached_at IS NULL OR
    (attempt_row.provider_started_at IS NULL AND
      attempt_row.provider_returned_at IS NULL) OR
    (reservation_row.materialization_intent_id=p_intent_id AND
     reservation_row.materialization_generation_id=
       population.population_generation_id AND
     reservation_row.storage_domain_id=population.storage_domain_id AND
     (reservation_row.compensation_status='compensated' OR
      ack_row.status='done'));
  IF NOT coalesce(cleanup_authorized,false) THEN RETURN NULL; END IF;
  binding:=jsonb_build_object('installationId',install.installation_id::text,
    'storageDomainId',install.storage_domain_id::text,
    'verifierPolicySha256',install.verifier_policy_sha256,
    'ownerUserId',p_user_id::text,'attemptId',attempt_row.id::text,
    'intentId',p_intent_id::text,
    'populationGenerationId',population.population_generation_id::text,
    'namespaceId',population.population_namespace_id::text,
    'dispatchId',intent_row.dispatch_id::text,
    'populationFenceSha256',population.population_fence_sha256);
  evidence:=jsonb_build_object('planSha256',population.plan_sha256,
    'tombstoneSha256',creative_craft_json_sha256(jsonb_build_object(
      'schemaVersion',1,'installationId',install.installation_id::text,
      'intentId',p_intent_id::text,
      'populationGenerationId',population.population_generation_id::text,
      'namespaceId',population.population_namespace_id::text,
      'storageDomainId',population.storage_domain_id::text,
      'planSha256',population.plan_sha256)),
    'journalEntrySha256',creative_craft_json_sha256(jsonb_build_object(
      'schemaVersion',1,'installationId',install.installation_id::text,
      'intentId',p_intent_id::text,
      'populationGenerationId',population.population_generation_id::text,
      'namespaceId',population.population_namespace_id::text,
      'storageDomainId',population.storage_domain_id::text,
      'planSha256',population.plan_sha256,
      'tombstoneSha256',creative_craft_json_sha256(jsonb_build_object(
        'schemaVersion',1,'installationId',install.installation_id::text,
        'intentId',p_intent_id::text,
        'populationGenerationId',population.population_generation_id::text,
        'namespaceId',population.population_namespace_id::text,
        'storageDomainId',population.storage_domain_id::text,
        'planSha256',population.plan_sha256)),'dataNamespaceAbsent',true)),
    'beforeTreeSha256',creative_craft_json_sha256(jsonb_build_object(
      'inputs',population.plan->'inputs','expectedOutputs',population.plan->'expectedOutputs')));
  INSERT INTO creative_craft_physical_challenges(
    user_id,challenge_id,receipt_id,installation_id,phase,attempt_id,
    target_lease_token,materialization_intent_id,materialization_generation_id,
    storage_domain_id,binding,evidence,verifier_proof,issued_role)
  VALUES(p_user_id,challenge,receipt,install.installation_id,
    'materialization_forget',attempt_row.id,p_lease_token,p_intent_id,
    population.population_generation_id,install.storage_domain_id,binding,evidence,
    jsonb_build_object('plan',population.plan,
      'populationFenceSha256',population.population_fence_sha256),
    current_setting('role',true)) ON CONFLICT DO NOTHING;
  SELECT * INTO stored FROM creative_craft_physical_challenges
   WHERE user_id=p_user_id AND phase='materialization_forget'
     AND materialization_intent_id=p_intent_id
     AND materialization_generation_id=population.population_generation_id
     AND target_lease_token=p_lease_token;
  RETURN jsonb_build_object('challengeId',stored.challenge_id::text,
    'receiptId',stored.receipt_id::text,'phase',stored.phase,
    'binding',stored.binding,'evidence',stored.evidence,'proof',stored.verifier_proof);
END $$;

CREATE OR REPLACE FUNCTION creative_craft_materialization_complete_cleanup(
  p_user_id uuid,p_intent_id uuid,p_lease_token uuid,p_receipt_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; seed record; attempt_row record; intent_row record;
        population record; proof record; reservation_row record; ack_row record;
        cleanup_authorized boolean;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  SELECT attempt_id INTO seed FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id;
  IF NOT FOUND THEN RETURN false; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(seed.attempt_id));
  SELECT * INTO attempt_row FROM creative_execution_attempts
   WHERE user_id=p_user_id AND id=seed.attempt_id FOR UPDATE;
  SELECT * INTO reservation_row FROM creative_craft_launcher_reservations
   WHERE user_id=p_user_id AND attempt_id=seed.attempt_id FOR UPDATE;
  SELECT * INTO ack_row FROM creative_craft_launcher_ack_outbox
   WHERE user_id=p_user_id AND source_attempt_id=seed.attempt_id FOR UPDATE;
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND intent_id=p_intent_id FOR UPDATE;
  SELECT receipt.*,challenge.materialization_intent_id,
         challenge.materialization_generation_id,challenge.target_lease_token,
         challenge.storage_domain_id,challenge.binding,challenge.evidence
    INTO proof FROM creative_craft_physical_receipts receipt
    JOIN creative_craft_physical_challenges challenge
      ON challenge.user_id=receipt.user_id AND challenge.challenge_id=receipt.challenge_id
   WHERE receipt.user_id=p_user_id AND receipt.receipt_id=p_receipt_id
     AND receipt.phase='materialization_forget' FOR SHARE OF receipt,challenge;
  SELECT * INTO population FROM creative_craft_materialization_populations
   WHERE user_id=p_user_id AND intent_id=p_intent_id
     AND population_generation_id=proof.materialization_generation_id FOR UPDATE;
  cleanup_authorized:=population.attached_at IS NULL OR
    (attempt_row.provider_started_at IS NULL AND
      attempt_row.provider_returned_at IS NULL) OR
    (reservation_row.materialization_intent_id=p_intent_id AND
     reservation_row.materialization_generation_id=
       population.population_generation_id AND
     reservation_row.storage_domain_id=population.storage_domain_id AND
     (reservation_row.compensation_status='compensated' OR
      ack_row.status='done'));
  IF NOT coalesce(cleanup_authorized,false) THEN RETURN false; END IF;
  IF population.state='forgotten' THEN
    RETURN proof.receipt_id IS NOT NULL
      AND proof.target_lease_token=p_lease_token
      AND proof.storage_domain_id=population.storage_domain_id
      AND EXISTS(SELECT 1 FROM creative_craft_physical_receipt_consumptions c
        WHERE c.user_id=p_user_id AND c.receipt_id=p_receipt_id
          AND c.completion_kind='materialization_cleanup'
          AND c.materialization_generation_id=population.population_generation_id);
  END IF;
  IF proof.receipt_id IS NOT NULL
     AND proof.materialization_intent_id=p_intent_id
     AND proof.materialization_generation_id=population.population_generation_id
     AND proof.target_lease_token=p_lease_token
     AND (population.state<>'cleanup_committed'
          OR population.cleanup_lease_token<>p_lease_token) THEN
    INSERT INTO creative_craft_physical_receipt_consumptions(
      user_id,receipt_id,completion_kind,attempt_id,materialization_generation_id)
    VALUES(p_user_id,p_receipt_id,'materialization_rejected',intent_row.attempt_id,
      population.population_generation_id) ON CONFLICT DO NOTHING;
    RETURN false;
  END IF;
  IF population.state<>'cleanup_committed'
     OR population.cleanup_lease_token<>p_lease_token
     OR population.cleanup_lease_until<=clock_timestamp()
     OR proof.receipt_id IS NULL OR proof.materialization_intent_id<>p_intent_id
     OR proof.materialization_generation_id<>population.population_generation_id
     OR proof.target_lease_token<>p_lease_token
     OR proof.storage_domain_id<>population.storage_domain_id
     OR proof.binding->>'populationFenceSha256'<>population.population_fence_sha256
     OR proof.evidence->>'planSha256'<>population.plan_sha256
     OR EXISTS(SELECT 1 FROM creative_craft_physical_receipt_consumptions c
                WHERE c.user_id=p_user_id AND c.receipt_id=p_receipt_id)
  THEN RETURN false; END IF;
  INSERT INTO creative_craft_physical_receipt_consumptions(
    user_id,receipt_id,completion_kind,attempt_id,materialization_generation_id)
  VALUES(p_user_id,p_receipt_id,'materialization_cleanup',intent_row.attempt_id,
    population.population_generation_id);
  UPDATE creative_craft_materialization_populations SET state='forgotten',
    cleanup_lease_token=NULL,cleanup_lease_until=NULL,
    forgotten_at=clock_timestamp(),updated_at=clock_timestamp()
   WHERE user_id=p_user_id
     AND population_generation_id=population.population_generation_id
     AND state='cleanup_committed' AND cleanup_lease_token=p_lease_token;
  IF NOT EXISTS(SELECT 1 FROM creative_craft_materialization_populations p
      WHERE p.user_id=p_user_id AND p.intent_id=p_intent_id
        AND p.state<>'forgotten')
     AND intent_row.state IN ('writing','attached','legacy_attached') THEN
    UPDATE creative_craft_materialization_intents SET state='forgotten',
      forgotten_at=clock_timestamp(),updated_at=clock_timestamp()
     WHERE user_id=p_user_id AND intent_id=p_intent_id
       AND state IN ('writing','attached','legacy_attached');
  END IF;
  RETURN true;
END $$;

CREATE FUNCTION creative_craft_population_guard() RETURNS trigger
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
  IF NOT (
    (OLD.state='claimed_unbound' AND NEW.state IN ('writing','forgotten')) OR
    (OLD.state='writing' AND NEW.state IN ('receipt_ready','cleanup_required')) OR
    (OLD.state='receipt_ready' AND NEW.state IN ('finalizing','cleanup_required')) OR
    (OLD.state='finalizing' AND NEW.state IN ('finalizing','receipt_ready','attached','cleanup_required')) OR
    (OLD.state='cleanup_required' AND
       NEW.state IN ('cleanup_required','cleanup_running')) OR
    (OLD.state='cleanup_running' AND
       NEW.state IN ('cleanup_running','cleanup_required','cleanup_committed')) OR
    (OLD.state='cleanup_committed' AND NEW.state IN ('cleanup_committed','forgotten')) OR
    (OLD.state IN ('attached','legacy_attached') AND
       NEW.state='cleanup_required')) THEN
    RAISE EXCEPTION 'invalid Craft population transition' USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER creative_craft_population_guard
BEFORE UPDATE ON creative_craft_materialization_populations
FOR EACH ROW EXECUTE FUNCTION creative_craft_population_guard();
CREATE FUNCTION creative_craft_population_definer_write_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE completion_owner text; deletion_authorized boolean;
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
    RAISE EXCEPTION 'Craft populations are deleted only with their account'
      USING ERRCODE='42501';
  END IF;
  SELECT completion_definer_role
    INTO completion_owner
    FROM creative_craft_physical_installation_bindings;
  IF current_user=completion_owner THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'Craft population writes require the scoped definer API'
    USING ERRCODE='42501';
END $$;
CREATE TRIGGER creative_craft_population_definer_only
BEFORE INSERT OR UPDATE OR DELETE ON creative_craft_materialization_populations
FOR EACH ROW EXECUTE FUNCTION creative_craft_population_definer_write_guard();

CREATE FUNCTION creative_craft_population_terminal_cleanup() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF TG_TABLE_NAME='creative_craft_launcher_reservations'
     AND to_jsonb(NEW)->>'compensation_status'='compensated'
     AND to_jsonb(OLD)->>'compensation_status'<>'compensated' THEN
    UPDATE creative_craft_materialization_populations SET state='cleanup_required',
      available_at=clock_timestamp(),updated_at=clock_timestamp()
     WHERE user_id=NEW.user_id
       AND population_generation_id=NEW.materialization_generation_id
       AND state IN ('attached','legacy_attached');
  ELSIF TG_TABLE_NAME='creative_craft_launcher_ack_outbox'
     AND to_jsonb(NEW)->>'status'='done'
     AND to_jsonb(OLD)->>'status'<>'done' THEN
    UPDATE creative_craft_materialization_populations p SET state='cleanup_required',
      available_at=clock_timestamp(),updated_at=clock_timestamp()
     FROM creative_craft_launcher_reservations r
     WHERE r.user_id=NEW.user_id AND r.attempt_id=NEW.source_attempt_id
       AND p.user_id=r.user_id
       AND p.population_generation_id=r.materialization_generation_id
       AND p.state IN ('attached','legacy_attached');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER creative_craft_population_compensation_forgotten
AFTER UPDATE OF compensation_status ON creative_craft_launcher_reservations
FOR EACH ROW EXECUTE FUNCTION creative_craft_population_terminal_cleanup();
CREATE TRIGGER creative_craft_population_ack_forgotten
AFTER UPDATE OF status ON creative_craft_launcher_ack_outbox
FOR EACH ROW EXECUTE FUNCTION creative_craft_population_terminal_cleanup();

CREATE OR REPLACE FUNCTION creative_craft_launcher_reservation_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (OLD.user_id,OLD.attempt_id,OLD.job_id,OLD.step_id,OLD.attempt_no,
      OLD.claim_lease_token,OLD.fence_epoch,OLD.admission_id,
      OLD.admission_sha256,OLD.claim_set_sha256,OLD.dispatch_id,
      OLD.request_sha256,OLD.request_authority,OLD.profile_id,
      OLD.profile_sha256,OLD.control_document,OLD.input_root,OLD.output_root,
      OLD.inputs,OLD.expected_outputs,OLD.limits,OLD.authority_sha256,
      OLD.materialization_intent_id,OLD.materialization_generation_id,
      OLD.storage_domain_id,OLD.prepared_at) IS DISTINCT FROM
     (NEW.user_id,NEW.attempt_id,NEW.job_id,NEW.step_id,NEW.attempt_no,
      NEW.claim_lease_token,NEW.fence_epoch,NEW.admission_id,
      NEW.admission_sha256,NEW.claim_set_sha256,NEW.dispatch_id,
      NEW.request_sha256,NEW.request_authority,NEW.profile_id,
      NEW.profile_sha256,NEW.control_document,NEW.input_root,NEW.output_root,
      NEW.inputs,NEW.expected_outputs,NEW.limits,NEW.authority_sha256,
      NEW.materialization_intent_id,NEW.materialization_generation_id,
      NEW.storage_domain_id,NEW.prepared_at) THEN
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
  IF NOT ((OLD.compensation_status='pending' AND
            NEW.compensation_status IN ('running','confirmed')) OR
          (OLD.compensation_status='confirmed' AND NEW.compensation_status='running') OR
          (OLD.compensation_status='running' AND
            NEW.compensation_status IN ('running','compensated'))) THEN
    RAISE EXCEPTION 'invalid creative craft launcher compensation transition';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION creative_craft_recover_expired_prestart(
  p_user_id uuid,p_attempt_id uuid,p_max_claims integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE owner_row record; intent_row record;
BEGIN
  PERFORM creative_craft_require_role('preparer');
  IF p_max_claims<1 OR p_max_claims>10 THEN
    RAISE EXCEPTION 'invalid Craft recovery claim limit' USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_account_advisory_key(p_user_id));
  SELECT deletion_requested_at INTO owner_row FROM users
   WHERE id=p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(creative_craft_attempt_advisory_key(p_attempt_id));
  SELECT * INTO intent_row FROM creative_craft_materialization_intents
   WHERE user_id=p_user_id AND attempt_id=p_attempt_id;
  IF EXISTS(SELECT 1 FROM creative_craft_materialization_populations p
      WHERE p.user_id=p_user_id AND p.intent_id=intent_row.intent_id
        AND p.state NOT IN ('forgotten','attached','legacy_attached')) THEN
    RETURN jsonb_build_object('outcome','cleanup_required','terminalStatus','pending');
  END IF;
  IF intent_row.state IN ('attached','legacy_attached') AND NOT EXISTS(
      SELECT 1 FROM creative_craft_launcher_reservations r
      JOIN creative_craft_materialization_populations p
        ON p.user_id=r.user_id
       AND p.population_generation_id=r.materialization_generation_id
       AND p.intent_id=r.materialization_intent_id
       AND p.attempt_id=r.attempt_id
       AND p.storage_domain_id=r.storage_domain_id
       AND p.state IN ('attached','legacy_attached')
       WHERE r.user_id=p_user_id AND r.attempt_id=p_attempt_id
         AND r.materialization_intent_id=intent_row.intent_id) THEN
    RAISE EXCEPTION 'attached materialization lost population reservation'
      USING ERRCODE='40001';
  END IF;
  RETURN creative_craft_recover_expired_prestart_raw114(
    p_user_id,p_attempt_id,p_max_claims);
END $$;

CREATE OR REPLACE FUNCTION creative_craft_provider_start_requires_materialization()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
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
        AND population.population_generation_id=reservation.materialization_generation_id
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
  RETURN NEW;
END $$;

DO $authority$
DECLARE s text:=current_schema(); f record; prep text; ack text; esc text;
        olddef text; vlaunch text; vstore text; physdef text; compdef text;
        caller_roles text; role_name text; relation_name text; database_oid oid;
BEGIN
  SELECT t.preparer_role,t.ack_role,t.escrow_role,t.definer_role,
         p.launcher_verifier_role,p.storage_verifier_role,
         p.receipt_definer_role,p.completion_definer_role,
         concat_ws(',',t.preparer_role,t.ack_role,t.escrow_role,
           p.launcher_verifier_role,p.storage_verifier_role)
    INTO prep,ack,esc,olddef,vlaunch,vstore,physdef,compdef,caller_roles
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p USING(installation_key);
  IF prep IS NULL THEN
    RAISE EXCEPTION 'Craft installation binding missing for 116'
      USING ERRCODE='55000';
  END IF;
  SELECT oid INTO database_oid FROM pg_database WHERE datname=current_database();

  -- Roles are cluster-global.  Recheck membership and every shared ownership/
  -- ACL dependency immediately before 116 changes owners or grants access.
  FOREACH role_name IN ARRAY ARRAY[
      prep,ack,esc,olddef,vlaunch,vstore,physdef,compdef] LOOP
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
                 WHERE namespace.oid=dependency.objid AND namespace.nspname=s)
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
      RAISE EXCEPTION 'Craft role changed before 116 grants: %',role_name
        USING ERRCODE='55000';
    END IF;
  END LOOP;
  FOREACH role_name IN ARRAY ARRAY[
      prep,ack,esc,olddef,vlaunch,vstore] LOOP
    IF has_table_privilege(role_name,
         format('%I.creative_craft_physical_challenges',s),
         'SELECT,INSERT,UPDATE,DELETE')
       OR has_table_privilege(role_name,
         format('%I.creative_craft_physical_receipts',s),
         'SELECT,INSERT,UPDATE,DELETE')
       OR has_table_privilege(role_name,
         format('%I.creative_craft_physical_receipt_consumptions',s),
         'SELECT,INSERT,UPDATE,DELETE')
       OR has_table_privilege(role_name,
         format('%I.creative_craft_materialization_intents',s),
         'SELECT,INSERT,UPDATE,DELETE')
       OR has_table_privilege(role_name,
         format('%I.creative_craft_materialization_populations',s),
         'SELECT,INSERT,UPDATE,DELETE') THEN
      RAISE EXCEPTION 'Craft caller gained direct evidence DML before 116 grants: %',
        role_name USING ERRCODE='55000';
    END IF;
  END LOOP;
  FOREACH role_name IN ARRAY ARRAY[prep,ack,esc,vlaunch,vstore] LOOP
    FOREACH relation_name IN ARRAY ARRAY[
      'users','creative_execution_jobs','creative_execution_steps',
      'creative_execution_attempts','creative_craft_launcher_reservations',
      'creative_runtime_reconciliation_outbox',
      'creative_craft_launcher_ack_outbox',
      'creative_craft_output_adoption_outbox','creative_candidate_receipts',
      'creative_candidate_states','creative_candidate_quarantines',
      'creative_candidate_quarantine_assets',
      'creative_candidate_native_projects','creative_native_project_revisions',
      'creative_craft_transition_installation_bindings',
      'creative_craft_physical_installation_bindings'] LOOP
      IF has_table_privilege(role_name,format('%I.%I',s,relation_name),
           'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN
        RAISE EXCEPTION 'Craft caller gained direct core DML before 116 grants: % on %',
          role_name,relation_name USING ERRCODE='55000';
      END IF;
    END LOOP;
  END LOOP;
  IF has_table_privilege(physdef,
       format('%I.creative_craft_physical_challenges',s),'INSERT,DELETE')
     OR has_table_privilege(physdef,
       format('%I.creative_craft_physical_receipt_consumptions',s),'INSERT,DELETE')
     OR has_table_privilege(compdef,
       format('%I.creative_craft_physical_receipts',s),'INSERT,DELETE')
     OR has_table_privilege(physdef,
       format('%I.creative_craft_materialization_populations',s),
       'INSERT,UPDATE,DELETE')
     OR has_table_privilege(compdef,
       format('%I.creative_craft_materialization_populations',s),
       'SELECT,INSERT,UPDATE,DELETE') THEN
    RAISE EXCEPTION 'Craft definer evidence ACL changed before 116 grants'
      USING ERRCODE='55000';
  END IF;

  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
    'creative_craft_materialization_begin',
    'creative_craft_materialization_bind_plan',
    'creative_craft_materialization_claim_population',
    'creative_craft_materialization_bind_population',
    'creative_craft_materialization_release_population',
    'creative_craft_issue_materialization_populate_challenge',
    'creative_craft_materialization_claim_finalize',
    'creative_craft_materialization_release_finalize',
    'creative_craft_materialization_finalize',
    'creative_craft_materialization_claim_cleanup',
    'creative_craft_materialization_commit_cleanup',
    'creative_craft_materialization_release_cleanup',
    'creative_craft_issue_materialization_forget_challenge',
    'creative_craft_materialization_complete_cleanup',
    'creative_craft_recover_expired_prestart',
    'creative_craft_recover_expired_prestart_raw114',
    'creative_craft_preparer_append_reservation_raw114',
    'creative_craft_accept_materialization_receipt',
    'creative_craft_population_terminal_cleanup',
    'creative_craft_provider_start_requires_materialization') LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.signature,compdef);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
    'creative_craft_launcher_challenge_load',
    'creative_craft_verify_materialization_challenge',
    'creative_craft_verify_materialization_populate',
    'creative_craft_verify_materialization_forget') LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO %I',f.signature,physdef);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname=s AND p.proname IN (
    'creative_craft_sha1','creative_craft_uuid5',
    'creative_craft_materialization_intent_guard',
    'creative_craft_materialization_logical_plan_guard',
    'creative_craft_population_guard',
    'creative_craft_population_definer_write_guard',
    'creative_craft_materialization_begin',
    'creative_craft_materialization_bind_plan',
    'creative_craft_materialization_claim_population',
    'creative_craft_materialization_bind_population',
    'creative_craft_materialization_release_population',
    'creative_craft_issue_materialization_populate_challenge',
    'creative_craft_materialization_claim_finalize',
    'creative_craft_materialization_release_finalize',
    'creative_craft_materialization_finalize',
    'creative_craft_materialization_claim_cleanup',
    'creative_craft_materialization_commit_cleanup',
    'creative_craft_materialization_release_cleanup',
    'creative_craft_issue_materialization_forget_challenge',
    'creative_craft_materialization_complete_cleanup',
    'creative_craft_launcher_challenge_load',
    'creative_craft_verify_materialization_challenge',
    'creative_craft_verify_materialization_populate',
    'creative_craft_verify_materialization_forget',
    'creative_craft_accept_materialization_receipt',
    'creative_craft_provider_start_requires_materialization',
    'creative_craft_recover_expired_prestart',
    'creative_craft_recover_expired_prestart_raw114',
    'creative_craft_preparer_append_reservation_raw114',
    'creative_craft_population_terminal_cleanup') LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path TO pg_catalog,%I,pg_temp',
                   f.signature,s);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,uonify_creative_evaluator,uonify_creative_reviewer,%s',
                   f.signature,caller_roles);
  END LOOP;
  REVOKE ALL ON creative_craft_materialization_intents
    FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,
         uonify_creative_evaluator,uonify_creative_reviewer;
  EXECUTE format('REVOKE ALL ON TABLE %I.creative_craft_materialization_intents FROM %s',s,caller_roles);
  REVOKE ALL ON creative_craft_materialization_populations
    FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,
         uonify_creative_evaluator,uonify_creative_reviewer;
  EXECUTE format('REVOKE ALL ON TABLE %I.creative_craft_materialization_populations FROM %s',s,caller_roles);

  EXECUTE format('GRANT SELECT,INSERT,UPDATE(state,plan,plan_sha256,request_sha256,request_authority,profile_sha256,authority_sha256,cleanup_lease_token,cleanup_lease_until,cleanup_attempt_count,cleanup_last_error,available_at,planned_at,attached_at,forgotten_at,updated_at) ON %I.creative_craft_materialization_intents TO %I',s,compdef);
  EXECUTE format('GRANT UPDATE(logical_plan,logical_plan_sha256) ON %I.creative_craft_materialization_intents TO %I',s,compdef);
  EXECUTE format('GRANT SELECT ON %I.creative_craft_materialization_intents TO %I',s,physdef);
  EXECUTE format('GRANT SELECT,INSERT,UPDATE(state,writer_lease_until,writer_consumed_at,plan,plan_sha256,request_sha256,request_authority,profile_sha256,authority_sha256,receipt_id,finalize_token,finalized_token,finalize_lease_until,finalize_attempt_count,cleanup_lease_token,cleanup_lease_until,cleanup_attempt_count,available_at,bound_at,receipt_ready_at,attached_at,forgotten_at,updated_at) ON %I.creative_craft_materialization_populations TO %I',s,compdef);
  EXECUTE format('GRANT SELECT ON %I.creative_craft_materialization_populations TO %I',s,physdef);
  EXECUTE format('GRANT INSERT ON %I.creative_craft_physical_receipts TO %I',s,compdef);
  EXECUTE format('GRANT INSERT(materialization_intent_id,materialization_generation_id,storage_domain_id) ON %I.creative_craft_launcher_reservations TO %I',s,compdef);
  EXECUTE format('GRANT SELECT,INSERT(materialization_intent_id,materialization_generation_id,storage_domain_id) ON %I.creative_craft_physical_challenges TO %I',s,compdef);
  EXECUTE format('GRANT SELECT(materialization_intent_id,materialization_generation_id,storage_domain_id) ON %I.creative_craft_physical_challenges TO %I',s,physdef);
  EXECUTE format('GRANT INSERT(storage_domain_id) ON %I.creative_craft_physical_receipts TO %I',s,physdef);
  EXECUTE format('GRANT INSERT(materialization_generation_id) ON %I.creative_craft_physical_receipt_consumptions TO %I',s,compdef);

  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_materialization_begin(uuid,uuid),%I.creative_craft_materialization_bind_plan(uuid,uuid,uuid,jsonb),%I.creative_craft_materialization_claim_population(uuid,uuid,uuid),%I.creative_craft_materialization_bind_population(uuid,uuid,uuid,uuid,jsonb),%I.creative_craft_materialization_release_population(uuid,uuid,uuid,uuid),%I.creative_craft_issue_materialization_populate_challenge(uuid,uuid,uuid,uuid,uuid),%I.creative_craft_materialization_claim_finalize(uuid,uuid,uuid,uuid,uuid),%I.creative_craft_materialization_release_finalize(uuid,uuid,uuid,uuid,uuid,uuid),%I.creative_craft_materialization_finalize(uuid,uuid,uuid,uuid,uuid,uuid),%I.creative_craft_materialization_claim_cleanup(uuid,uuid),%I.creative_craft_materialization_commit_cleanup(uuid,uuid,uuid),%I.creative_craft_materialization_release_cleanup(uuid,uuid,uuid),%I.creative_craft_issue_materialization_forget_challenge(uuid,uuid,uuid),%I.creative_craft_materialization_complete_cleanup(uuid,uuid,uuid,uuid),%I.creative_craft_recover_expired_prestart(uuid,uuid,integer) TO %I',s,s,s,s,s,s,s,s,s,s,s,s,s,s,s,prep);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_launcher_challenge_load(uuid),%I.creative_craft_verify_materialization_populate(uuid),%I.creative_craft_verify_materialization_forget(uuid) TO %I',s,s,s,vlaunch);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_recover_expired_prestart_raw114(uuid,uuid,integer) TO %I',s,compdef);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_uuid5(uuid,text) TO %I',s,compdef);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_sha1(bytea) TO %I',s,compdef);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_verify_materialization_challenge(uuid,text) TO %I',s,physdef);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.creative_craft_accept_materialization_receipt(uuid,text) TO %I',s,physdef);
END $authority$;

-- Upgrade invariants: installation remains structurally inactive and no
-- ordinary application role can call or write the 116 authority directly.
DO $audit$
DECLARE s text:=current_schema(); binding record; role_name text;
BEGIN
  SELECT t.*,p.launcher_verifier_role,p.storage_verifier_role,
         p.receipt_definer_role,p.completion_definer_role INTO binding
    FROM creative_craft_transition_installation_bindings t
    JOIN creative_craft_physical_installation_bindings p USING(installation_key);
  IF binding.desired_active OR EXISTS(
    SELECT 1 FROM pg_roles r WHERE r.rolname IN (
      binding.preparer_role,binding.ack_role,binding.escrow_role,
      binding.definer_role,binding.launcher_verifier_role,
      binding.storage_verifier_role,binding.receipt_definer_role,
      binding.completion_definer_role)
      AND (r.rolcanlogin OR r.rolinherit OR r.rolsuper OR r.rolcreatedb
           OR r.rolcreaterole OR r.rolreplication OR r.rolbypassrls))
  THEN RAISE EXCEPTION 'Craft 116 installation is not inactive'
    USING ERRCODE='55000'; END IF;
  IF has_function_privilege('uonify_app_runtime',
       format('%I.creative_craft_materialization_begin(uuid,uuid)',s),'EXECUTE')
     OR has_table_privilege('uonify_app_runtime',
       format('%I.creative_craft_materialization_intents',s),'SELECT')
     OR has_function_privilege(binding.preparer_role,
       format('%I.creative_craft_preparer_append_reservation_raw114(uuid,uuid,jsonb)',s),
       'EXECUTE')
     OR has_column_privilege(binding.receipt_definer_role,
       format('%I.creative_craft_materialization_intents',s),
       'state','UPDATE')
     OR has_column_privilege(binding.receipt_definer_role,
       format('%I.creative_craft_materialization_populations',s),
       'state','UPDATE')
  THEN RAISE EXCEPTION 'Craft 116 raw authority leaked to a caller'
    USING ERRCODE='55000'; END IF;
END $audit$;
