-- Run after the model as a local fixture administrator. All checks use SET ROLE.
BEGIN;
INSERT INTO plataforma.users(id,email,display_name) VALUES
 ('10000000-0000-0000-0000-000000000001','owner-security@example.invalid','Owner'),
 ('10000000-0000-0000-0000-000000000002','member-security@example.invalid','Member');
INSERT INTO plataforma.tenants(id,code,slug,name) VALUES
 ('20000000-0000-0000-0000-000000000001','security-test','security-test','Security');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id)
 SELECT '20000000-0000-0000-0000-000000000001',
 '10000000-0000-0000-0000-000000000001',id FROM plataforma.roles WHERE code='tenant.owner';
INSERT INTO plataforma.user_tenants(tenant_id,user_id) VALUES
 ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002');
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN IF current_user <> 'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF; END $$;
SELECT set_config('app.current_user_id','10000000-0000-0000-0000-000000000001',true);
SELECT set_config('app.current_tenant_id','20000000-0000-0000-0000-000000000001',true);
DO $$ DECLARE n integer; BEGIN
 UPDATE plataforma.tenants SET name='Owner allowed';
 GET DIAGNOSTICS n=ROW_COUNT;
 IF n<>1 THEN RAISE EXCEPTION 'Owner update failed'; END IF;
END $$;
SELECT set_config('app.current_user_id','10000000-0000-0000-0000-000000000002',true);
DO $$ DECLARE n integer; BEGIN
 UPDATE plataforma.tenants SET name='Member denied';
 GET DIAGNOSTICS n=ROW_COUNT;
 IF n<>0 THEN RAISE EXCEPTION 'Member updated tenant'; END IF;
 BEGIN
  UPDATE plataforma.roles SET name='Escalation';
  RAISE EXCEPTION 'Role update was allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN
  PERFORM plataforma.create_tenant_with_owner('bad','bad','bad','individual',
    '10000000-0000-0000-0000-000000000001');
  RAISE EXCEPTION 'Owner spoofing was allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('app.current_tenant_id','',true);
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM plataforma.tenants) THEN
  RAISE EXCEPTION 'Missing tenant context exposed data'; END IF;
END $$;
-- All fixtures belong to this transaction; collisions fail without overwriting.
RESET ROLE;
INSERT INTO plataforma.users(id,email,display_name) VALUES
 ('10000000-0000-0000-0000-000000000003','outsider-security@example.invalid','Outsider');
INSERT INTO plataforma.tenants(id,code,slug,name) VALUES
 ('20000000-0000-0000-0000-000000000002','security-other','security-other','Other');
INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation) VALUES
 ('security-owner-key','10000000-0000-0000-0000-000000000001','tenant.create'),
 ('security-member-key','10000000-0000-0000-0000-000000000002','tenant.create');

CREATE FUNCTION pg_temp.assert_app() RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF current_user <> 'mastererp_app' THEN
 RAISE EXCEPTION 'Expected effective mastererp_app, got %', current_user;
END IF; END $$;
CREATE FUNCTION pg_temp.denied(statement text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 PERFORM pg_temp.assert_app();
 BEGIN
  EXECUTE statement;
 EXCEPTION WHEN insufficient_privilege THEN RETURN;
 END;
 RAISE EXCEPTION 'Expected authorization denial';
END $$;
SET LOCAL ROLE mastererp_app;
SELECT pg_temp.assert_app();
SELECT set_config('app.current_user_id','10000000-0000-0000-0000-000000000001',true);
SELECT set_config('app.current_tenant_id','20000000-0000-0000-0000-000000000001',true);
INSERT INTO plataforma.onboarding_sessions(id,tenant_id,initiated_by_user_id) VALUES
 ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001');
SELECT pg_temp.denied($q$UPDATE plataforma.onboarding_sessions
 SET tenant_id='20000000-0000-0000-0000-000000000002'
 WHERE id='30000000-0000-0000-0000-000000000001'$q$);
SELECT pg_temp.denied($q$INSERT INTO plataforma.onboarding_sessions(tenant_id,initiated_by_user_id)
 VALUES('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001')$q$);
-- Owner provisioning primitives: tenant activation, module and company creation.
UPDATE plataforma.tenants SET status='active' WHERE id='20000000-0000-0000-0000-000000000001';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '20000000-0000-0000-0000-000000000001',id,'active'
 FROM plataforma.modules WHERE code='video.creation';
INSERT INTO organizacion.companies(tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('20000000-0000-0000-0000-000000000001','Security fixture','US','USD','UTC');
SELECT set_config('app.current_operation','tenant.create',true);
DO $$ BEGIN
 PERFORM pg_temp.assert_app();
 IF (SELECT count(*) FROM plataforma.idempotency_keys
 WHERE idempotency_key IN ('security-owner-key','security-member-key')) <> 1 THEN
 RAISE EXCEPTION 'Actor idempotency isolation failed'; END IF;
END $$;
SELECT set_config('app.current_operation','other.operation',true);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM plataforma.idempotency_keys
 WHERE idempotency_key IN ('security-owner-key','security-member-key')) THEN
 RAISE EXCEPTION 'Operation idempotency isolation failed'; END IF; END $$;
SELECT pg_temp.denied($q$UPDATE plataforma.idempotency_keys SET response_body='{}'$q$);
SELECT set_config('app.current_user_id','10000000-0000-0000-0000-000000000002',true);
SELECT pg_temp.denied($q$INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '20000000-0000-0000-0000-000000000001',id,'active'
 FROM plataforma.modules WHERE code='erp.finance'$q$);
SELECT pg_temp.denied($q$INSERT INTO organizacion.companies(tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('20000000-0000-0000-0000-000000000001','Denied','US','USD','UTC')$q$);
SELECT set_config('app.current_user_id','10000000-0000-0000-0000-000000000003',true);
DO $$ DECLARE n integer; BEGIN
 PERFORM pg_temp.assert_app();
 IF EXISTS(SELECT 1 FROM plataforma.tenants) OR EXISTS(SELECT 1 FROM plataforma.onboarding_sessions)
 THEN RAISE EXCEPTION 'Outsider read allowed'; END IF;
 UPDATE plataforma.tenants SET name='Denied' WHERE id='20000000-0000-0000-0000-000000000001';
 GET DIAGNOSTICS n=ROW_COUNT;
 IF n<>0 THEN RAISE EXCEPTION 'Outsider update allowed'; END IF;
END $$;
SELECT set_config('app.current_user_id','',true);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM plataforma.tenants) THEN
 RAISE EXCEPTION 'Missing actor read allowed'; END IF; END $$;
SELECT set_config('app.current_user_id','10000000-0000-0000-0000-000000000001',true);
SELECT set_config('app.current_tenant_id','20000000-0000-0000-0000-000000000002',true);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM plataforma.tenants) THEN
 RAISE EXCEPTION 'Incompatible context read allowed'; END IF; END $$;
SELECT set_config('app.current_tenant_id','',true);
DO $$ DECLARE a uuid; b uuid; BEGIN
 PERFORM pg_temp.assert_app();
 a := plataforma.create_tenant_with_owner('security-created','security-created','Security created','individual',
 '10000000-0000-0000-0000-000000000001','security-create-cache');
 b := plataforma.create_tenant_with_owner('security-created','security-created','Security created','individual',
 '10000000-0000-0000-0000-000000000001','security-create-cache');
 IF a IS DISTINCT FROM b THEN RAISE EXCEPTION 'Idempotent creation failed'; END IF;
END $$;
RESET ROLE;
ROLLBACK;
