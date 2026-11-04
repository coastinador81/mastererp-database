BEGIN;
-- Run inside the official rollback-only test transaction, using existing isolated fixtures.
INSERT INTO plataforma.roles(id,code,name) VALUES('00008000-0000-0000-0000-000000000015','qa-frontend-context','Frontend context test');
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 VALUES('00008000-0000-0000-0000-000000000015','administration.parties.read');
INSERT INTO plataforma.users(id,email,display_name) VALUES('00008001-0000-0000-0000-000000000015','qa-frontend-context@example.invalid','Frontend context test');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00008002-0000-0000-0000-000000000015','qa-frontend-context','qa-frontend-context','Frontend context test','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status) VALUES('00008002-0000-0000-0000-000000000015','00008001-0000-0000-0000-000000000015','00008000-0000-0000-0000-000000000015','active');
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00008002-0000-0000-0000-000000000015',id,'active' FROM plataforma.modules WHERE code='erp.finance';
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00008003-0000-0000-0000-000000000015','00008002-0000-0000-0000-000000000015','Frontend context company','US','USD','UTC');
SET LOCAL ROLE mastererp_app;
SELECT set_config('app.current_user_id','00008001-0000-0000-0000-000000000015',true),set_config('app.current_tenant_id','00008002-0000-0000-0000-000000000015',true);
DO $$ DECLARE c jsonb; rejected boolean:=false; BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 c:=plataforma.current_frontend_context();
 IF jsonb_array_length(c->'companies')<>1 OR NOT(c->'permissions' ? 'administration.parties.read')
 OR c->'permissions' ? 'administration.parties.write' THEN RAISE EXCEPTION 'Wrong context'; END IF;
 PERFORM set_config('app.current_tenant_id','00000000-0000-0000-0000-000000000000',true);
 BEGIN PERFORM plataforma.current_frontend_context(); EXCEPTION WHEN insufficient_privilege THEN rejected:=true; END;
 IF NOT rejected THEN RAISE EXCEPTION 'Foreign context accepted'; END IF;
END $$;
RESET ROLE;
UPDATE plataforma.user_tenants SET permissions_override='{"administration.parties.read":false}'::jsonb
 WHERE tenant_id='00008002-0000-0000-0000-000000000015';
SET LOCAL ROLE mastererp_app;
SELECT set_config('app.current_tenant_id','00008002-0000-0000-0000-000000000015',true);
DO $$ DECLARE c jsonb; BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 c:=plataforma.current_frontend_context();
 IF jsonb_array_length(c->'companies')<>0 OR c->'permissions' ? 'administration.parties.read' THEN RAISE EXCEPTION 'Override ignored'; END IF;
END $$;
RESET ROLE;

ROLLBACK;
