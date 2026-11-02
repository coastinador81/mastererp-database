-- Disposable database only. Fixture writes roll back. All access tests SET ROLE.
BEGIN;
INSERT INTO plataforma.users(id,email,display_name,status) VALUES
 ('61000000-0000-0000-0000-000000000001','identity-owner@example.invalid','Identity test owner','active'),
 ('61000000-0000-0000-0000-000000000002','identity-member@example.invalid','Identity test member','active'),
 ('61000000-0000-0000-0000-000000000003','identity-inactive@example.invalid','Identity test inactive','disabled');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES
 ('62000000-0000-0000-0000-000000000001','identity-test-a','identity-test-a','Identity test A','active'),
 ('62000000-0000-0000-0000-000000000002','identity-test-b','identity-test-b','Identity test B','active'),
 ('62000000-0000-0000-0000-000000000003','identity-test-off','identity-test-off','Identity test inactive','suspended');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id)
 SELECT t.id,'61000000-0000-0000-0000-000000000001',r.id
 FROM plataforma.tenants t CROSS JOIN plataforma.roles r
 WHERE t.code IN ('identity-test-a','identity-test-b','identity-test-off') AND r.code='tenant.owner';
INSERT INTO plataforma.user_tenants(tenant_id,user_id) VALUES
 ('62000000-0000-0000-0000-000000000001','61000000-0000-0000-0000-000000000002');
INSERT INTO plataforma.external_identities(issuer,subject,user_id) VALUES
 ('https://identity-test.invalid','owner','61000000-0000-0000-0000-000000000001'),
 ('https://identity-test.invalid','member','61000000-0000-0000-0000-000000000002'),
 ('https://identity-test.invalid','inactive','61000000-0000-0000-0000-000000000003');
DO $$ BEGIN
 BEGIN
  INSERT INTO plataforma.external_identities(issuer,subject,user_id) VALUES
   ('https://identity-test.invalid','owner','61000000-0000-0000-0000-000000000002');
  RAISE EXCEPTION 'Conflicting issuer/sub binding accepted';
 EXCEPTION WHEN unique_violation THEN NULL; END;
END $$;
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN
 IF current_user <> 'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 IF plataforma.resolve_external_identity('https://other.invalid','owner') IS NOT NULL
 OR plataforma.resolve_external_identity('https://identity-test.invalid','unknown') IS NOT NULL
 OR plataforma.resolve_external_identity('https://identity-test.invalid','identity-owner@example.invalid') IS NOT NULL
 OR plataforma.resolve_external_identity('https://identity-test.invalid','inactive') IS NOT NULL
 THEN RAISE EXCEPTION 'Identity binding failure'; END IF;
 IF plataforma.resolve_external_identity('https://identity-test.invalid','owner') IS DISTINCT FROM
 '61000000-0000-0000-0000-000000000001'::uuid THEN RAISE EXCEPTION 'Owner lookup failed'; END IF;
 IF plataforma.has_current_tenant_permission('uonify.connections.manage') THEN
 RAISE EXCEPTION 'Missing context authorized'; END IF;
 BEGIN
 INSERT INTO plataforma.external_identities VALUES('https://spoof.invalid','spoof',
 '61000000-0000-0000-0000-000000000002','active',now());
 RAISE EXCEPTION 'Identity write allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN
 DELETE FROM plataforma.role_permissions;
 RAISE EXCEPTION 'Permission write allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('app.current_user_id','61000000-0000-0000-0000-000000000001',true);
SELECT set_config('app.current_tenant_id','62000000-0000-0000-0000-000000000001',true);
DO $$ BEGIN
 IF NOT plataforma.has_current_tenant_permission('uonify.connections.manage') THEN
 RAISE EXCEPTION 'Owner denied'; END IF;
 IF (SELECT count(*) FROM plataforma.list_current_user_spaces())<>2 THEN
 RAISE EXCEPTION 'Active multi-tenant listing failure'; END IF;
END $$;
SELECT set_config('app.current_tenant_id','62000000-0000-0000-0000-000000000003',true);
DO $$ BEGIN IF plataforma.has_current_tenant_permission('uonify.connections.manage') THEN
 RAISE EXCEPTION 'Inactive tenant authorized'; END IF; END $$;
SELECT set_config('app.current_user_id','61000000-0000-0000-0000-000000000002',true);
SELECT set_config('app.current_tenant_id','62000000-0000-0000-0000-000000000001',true);
DO $$ BEGIN IF plataforma.has_current_tenant_permission('uonify.connections.manage') THEN
 RAISE EXCEPTION 'Ordinary member authorized'; END IF; END $$;
DO $$ BEGIN IF (SELECT count(*) FROM plataforma.list_current_user_spaces())<>1 THEN
 RAISE EXCEPTION 'Previous actor spaces leaked after actor switch'; END IF; END $$;
SELECT set_config('app.current_tenant_id','62000000-0000-0000-0000-000000000002',true);
DO $$ BEGIN
 IF plataforma.has_current_tenant_permission('uonify.connections.manage') THEN
 RAISE EXCEPTION 'Foreign tenant authorized'; END IF;
 IF EXISTS(SELECT 1 FROM plataforma.tenants) THEN RAISE EXCEPTION 'Foreign RLS exposure'; END IF;
END $$;
RESET ROLE;
UPDATE plataforma.user_tenants SET permissions_override='{"uonify.connections.manage":false}'
 WHERE user_id='61000000-0000-0000-0000-000000000001';
SET LOCAL ROLE mastererp_app;
SELECT set_config('app.current_user_id','61000000-0000-0000-0000-000000000001',true);
SELECT set_config('app.current_tenant_id','62000000-0000-0000-0000-000000000001',true);
DO $$ BEGIN IF plataforma.has_current_tenant_permission('uonify.connections.manage') THEN
 RAISE EXCEPTION 'Explicit revocation ignored'; END IF; END $$;
RESET ROLE;
UPDATE plataforma.user_tenants SET permissions_override='{"uonify.connections.manage":true}'
 WHERE user_id='61000000-0000-0000-0000-000000000002';
SET LOCAL ROLE mastererp_app;
SELECT set_config('app.current_user_id','61000000-0000-0000-0000-000000000002',true);
DO $$ BEGIN IF NOT plataforma.has_current_tenant_permission('uonify.connections.manage') THEN
 RAISE EXCEPTION 'Explicit server-side permission denied'; END IF; END $$;
RESET ROLE;
UPDATE plataforma.user_tenants SET status='inactive'
 WHERE user_id='61000000-0000-0000-0000-000000000002';
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN IF plataforma.has_current_tenant_permission('uonify.connections.manage') THEN
 RAISE EXCEPTION 'Inactive membership authorized'; END IF; END $$;
ROLLBACK;
-- Same physical connection, next transaction: no actor/tenant from the fixture survives.
BEGIN;
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN
 IF current_user <> 'mastererp_app' THEN RAISE EXCEPTION 'Wrong reused-connection role'; END IF;
 IF plataforma.current_app_user_id() IS NOT NULL OR plataforma.current_app_tenant_id() IS NOT NULL
 THEN RAISE EXCEPTION 'Transaction-local identity context leaked'; END IF;
 IF EXISTS(SELECT 1 FROM plataforma.list_current_user_spaces())
 OR plataforma.has_current_tenant_permission('uonify.connections.manage')
 THEN RAISE EXCEPTION 'Reused connection exposed previous actor'; END IF;
END $$;
ROLLBACK;
