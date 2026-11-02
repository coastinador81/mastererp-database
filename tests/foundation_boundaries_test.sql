-- Synthetic fixture, never persistent. Access assertions run as mastererp_app.
BEGIN;
INSERT INTO plataforma.users(id,email,display_name) VALUES
 ('71000000-0000-0000-0000-000000000001','foundation-owner@example.invalid','Foundation owner'),
 ('71000000-0000-0000-0000-000000000002','foundation-outsider@example.invalid','Foundation outsider');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES
 ('72000000-0000-0000-0000-000000000001','foundation-a','foundation-a','Foundation A','active'),
 ('72000000-0000-0000-0000-000000000002','foundation-b','foundation-b','Foundation B','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id)
 SELECT t.id,'71000000-0000-0000-0000-000000000001',r.id
 FROM plataforma.tenants t CROSS JOIN plataforma.roles r
 WHERE t.code IN ('foundation-a','foundation-b') AND r.code='tenant.owner';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT t.id,m.id,'active' FROM plataforma.tenants t CROSS JOIN plataforma.modules m
 WHERE t.code IN ('foundation-a','foundation-b') AND m.code='uonify.core';
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone) VALUES
 ('73000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-000000000001','Foundation A','US','USD','UTC'),
 ('73000000-0000-0000-0000-000000000002','72000000-0000-0000-0000-000000000002','Foundation B','US','USD','UTC');
INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code) VALUES
 ('74000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-000000000001','73000000-0000-0000-0000-000000000001','a','Foundation A','office','US'),
 ('74000000-0000-0000-0000-000000000002','72000000-0000-0000-0000-000000000002','73000000-0000-0000-0000-000000000002','b','Foundation B','office','US');
INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,request_tenant_id) VALUES
 ('foundation-key-a','71000000-0000-0000-0000-000000000001','company.create','72000000-0000-0000-0000-000000000001'),
 ('foundation-key-b','71000000-0000-0000-0000-000000000001','company.create','72000000-0000-0000-0000-000000000002');
SET LOCAL ROLE mastererp_app;
SELECT set_config('app.current_user_id','71000000-0000-0000-0000-000000000001',true);
SELECT set_config('app.current_tenant_id','72000000-0000-0000-0000-000000000001',true);
SELECT set_config('app.current_operation','company.create',true);
DO $$ BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 IF (SELECT count(*) FROM plataforma.idempotency_keys)<>1 OR EXISTS
 (SELECT 1 FROM plataforma.idempotency_keys WHERE idempotency_key='foundation-key-b')
 THEN RAISE EXCEPTION 'Idempotency tenant boundary failed'; END IF;
 IF NOT plataforma.has_current_tenant_capability('uonify.core','uonify.connections.manage',
 '73000000-0000-0000-0000-000000000001','74000000-0000-0000-0000-000000000001') THEN RAISE EXCEPTION 'Owner denied'; END IF;
 IF plataforma.has_current_tenant_capability('uonify.core','uonify.connections.manage',
 '73000000-0000-0000-0000-000000000002') THEN RAISE EXCEPTION 'Foreign company accepted'; END IF;
 IF plataforma.has_current_tenant_capability('uonify.core','uonify.connections.manage',
 '73000000-0000-0000-0000-000000000001','74000000-0000-0000-0000-000000000002') THEN RAISE EXCEPTION 'Foreign branch accepted'; END IF;
 IF (SELECT count(*) FROM organizacion.companies)<>1 OR (SELECT count(*) FROM organizacion.branches)<>1
 THEN RAISE EXCEPTION 'Tenant data exposed'; END IF;
 BEGIN
  INSERT INTO organizacion.branches(tenant_id,company_id,code,name,branch_type,country_code)
  VALUES('72000000-0000-0000-0000-000000000001','73000000-0000-0000-0000-000000000002','bad','bad','office','US');
  RAISE EXCEPTION 'Foreign company association allowed';
 EXCEPTION WHEN foreign_key_violation OR insufficient_privilege THEN NULL; END;
 BEGIN
  UPDATE organizacion.branches SET company_id='73000000-0000-0000-0000-000000000002'
  WHERE id='74000000-0000-0000-0000-000000000001';
  RAISE EXCEPTION 'Foreign company reassociation allowed';
 EXCEPTION WHEN foreign_key_violation OR insufficient_privilege THEN NULL; END;
END $$;
-- Actor belongs to both tenants; context still isolates each one.
SELECT set_config('app.current_tenant_id','72000000-0000-0000-0000-000000000002',true);
DO $$ BEGIN
 IF NOT plataforma.has_current_tenant_capability('uonify.core','uonify.connections.manage')
 OR (SELECT id FROM organizacion.companies) <> '73000000-0000-0000-0000-000000000002'::uuid
 THEN RAISE EXCEPTION 'Second tenant isolation failed'; END IF;
 IF EXISTS(SELECT 1 FROM plataforma.idempotency_keys WHERE idempotency_key='foundation-key-a')
 THEN RAISE EXCEPTION 'Previous tenant idempotency leaked'; END IF;
END $$;
RESET ROLE;
UPDATE plataforma.user_tenants SET permissions_override='{"uonify.connections.manage":false}'
 WHERE tenant_id='72000000-0000-0000-0000-000000000002';
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN IF plataforma.has_current_tenant_capability('uonify.core','uonify.connections.manage')
 THEN RAISE EXCEPTION 'Explicit deny ignored'; END IF; END $$;
RESET ROLE;
UPDATE plataforma.user_tenants SET permissions_override='{}' WHERE tenant_id='72000000-0000-0000-0000-000000000002';
UPDATE plataforma.tenant_modules SET status='suspended' WHERE tenant_id='72000000-0000-0000-0000-000000000002';
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN IF plataforma.has_current_tenant_capability('uonify.core','uonify.connections.manage')
 THEN RAISE EXCEPTION 'Disabled module allowed'; END IF; END $$;
RESET ROLE;
UPDATE plataforma.tenant_modules SET status='active' WHERE tenant_id='72000000-0000-0000-0000-000000000002';
UPDATE plataforma.tenant_modules SET expires_at=now()-interval '1 minute' WHERE tenant_id='72000000-0000-0000-0000-000000000002';
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN IF plataforma.has_current_tenant_capability('uonify.core','uonify.connections.manage')
 THEN RAISE EXCEPTION 'Expired module allowed'; END IF; END $$;
RESET ROLE;
UPDATE plataforma.tenant_modules SET expires_at=NULL WHERE tenant_id='72000000-0000-0000-0000-000000000002';
UPDATE plataforma.tenants SET status='suspended' WHERE id='72000000-0000-0000-0000-000000000002';
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN
 IF plataforma.has_current_tenant_capability('uonify.core','uonify.connections.manage') OR EXISTS(SELECT 1 FROM organizacion.companies)
 THEN RAISE EXCEPTION 'Inactive tenant exposed'; END IF;
END $$;
RESET ROLE;
UPDATE plataforma.tenants SET status='active' WHERE id='72000000-0000-0000-0000-000000000002';
UPDATE plataforma.user_tenants SET status='inactive' WHERE tenant_id='72000000-0000-0000-0000-000000000002';
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN IF plataforma.has_current_tenant_capability('uonify.core','uonify.connections.manage')
 THEN RAISE EXCEPTION 'Inactive membership allowed'; END IF; END $$;
RESET ROLE;
UPDATE plataforma.user_tenants SET status='active' WHERE tenant_id='72000000-0000-0000-0000-000000000002';
UPDATE plataforma.users SET status='disabled' WHERE id='71000000-0000-0000-0000-000000000001';
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN IF plataforma.has_current_tenant_capability('uonify.core','uonify.connections.manage')
 THEN RAISE EXCEPTION 'Inactive user allowed'; END IF; END $$;
SELECT set_config('app.current_user_id','71000000-0000-0000-0000-000000000002',true);
DO $$ BEGIN IF plataforma.has_current_tenant_capability('uonify.core','uonify.connections.manage') OR EXISTS(SELECT 1 FROM organizacion.companies)
 THEN RAISE EXCEPTION 'Outsider allowed'; END IF; END $$;
DO $$ BEGIN
 BEGIN
  PERFORM organizacion.register_company_once('foundation-denied','Denied','US','USD','UTC',NULL);
  RAISE EXCEPTION 'Outsider registered company';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
ROLLBACK;
BEGIN;
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN
 IF current_user<>'mastererp_app' OR plataforma.current_app_user_id() IS NOT NULL
 OR plataforma.current_app_tenant_id() IS NOT NULL OR EXISTS(SELECT 1 FROM organizacion.companies)
 OR plataforma.has_current_tenant_capability('uonify.core','uonify.connections.manage')
 THEN RAISE EXCEPTION 'Transaction context leaked'; END IF;
END $$;
ROLLBACK;
