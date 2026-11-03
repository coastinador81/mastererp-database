BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-parties-sql','Parties SQL fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code) SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p WHERE r.code='qa-parties-sql' AND p.code IN ('administration.parties.read','administration.parties.write');
INSERT INTO plataforma.users(id,email,display_name) VALUES('00008001-0000-0000-0000-000000000001','qa-parties-local@example.invalid','Parties test');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00008002-0000-0000-0000-000000000001','qa-parties-local','qa-parties-local','Parties test','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00008002-0000-0000-0000-000000000001','00008001-0000-0000-0000-000000000001',id,'active' FROM plataforma.roles WHERE code='qa-parties-sql';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00008002-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code='erp.finance';
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00008003-0000-0000-0000-000000000001','00008002-0000-0000-0000-000000000001','Parties test','US','USD','UTC');
SELECT set_config('app.current_user_id','00008001-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','00008002-0000-0000-0000-000000000001',true),
 set_config('app.current_operation','administration.cliente.create',true),
 set_config('app.correlation_id','00008004-0000-0000-0000-000000000001',true);
SET LOCAL ROLE mastererp_app;
DO $$
DECLARE first jsonb; again jsonb; updated jsonb; third uuid; caught boolean;
BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 first:=administracion.party_write('00008003-0000-0000-0000-000000000001','cliente','create',NULL,'qa-test','Test',NULL,'first');
 third:=(first->>'id')::uuid;
 again:=administracion.party_write('00008003-0000-0000-0000-000000000001','cliente','create',NULL,'qa-test','Test',NULL,'first');
 IF again->>'id'<>first->>'id' OR (again->>'replayed')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'Replay failed'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.party_write('00008003-0000-0000-0000-000000000001','cliente','create',NULL,'qa-test','Different',NULL,'first');
 EXCEPTION WHEN unique_violation THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Content conflict not detected'; END IF;
 PERFORM set_config('app.current_operation','administration.proveedor.create',true);
 again:=administracion.party_write('00008003-0000-0000-0000-000000000001','proveedor','create',third,NULL,NULL,NULL,'supplier');
 IF again->>'id'<>first->>'id' OR jsonb_array_length(again->'roles')<>2 THEN RAISE EXCEPTION 'Shared master duplicated'; END IF;
 PERFORM set_config('app.current_operation','administration.cliente.update',true);
 updated:=administracion.party_write('00008003-0000-0000-0000-000000000001','cliente','update',third,'qa-test','Updated',1,NULL);
 IF (updated->>'version')::integer<>2 THEN RAISE EXCEPTION 'Version not advanced'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.party_write('00008003-0000-0000-0000-000000000001','cliente','update',third,'qa-test','Stale',1,NULL);
 EXCEPTION WHEN serialization_failure THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Stale write accepted'; END IF;
 IF administracion.parties_read('00008003-0000-0000-0000-000000000001','proveedor',third)->>'nombre'<>'Updated' THEN RAISE EXCEPTION 'Update not persisted'; END IF;
 IF has_table_privilege('mastererp_app','catalogo.terceros','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Direct DML leaked'; END IF;
 PERFORM set_config('app.current_tenant_id','',true);
 caught:=false;
 BEGIN PERFORM administracion.parties_read('00008003-0000-0000-0000-000000000001','cliente');
 EXCEPTION WHEN insufficient_privilege THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Missing context accepted'; END IF;
END $$;
ROLLBACK;
