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

INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00008002-0000-0000-0000-000000000002','qa-party-details-foreign','qa-party-details-foreign','Foreign details fixture','active');
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone) VALUES
 ('00008003-0000-0000-0000-000000000002','00008002-0000-0000-0000-000000000002','Foreign details fixture','US','USD','UTC'),
 ('00008003-0000-0000-0000-000000000003','00008002-0000-0000-0000-000000000001','Second details fixture','US','USD','UTC');
INSERT INTO plataforma.role_permissions(role_id,permission_code) SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p WHERE r.code='qa-parties-sql' AND p.code IN ('catalog.suppliers.read','catalog.suppliers.write');
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status) SELECT '00008002-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code='erp.catalog';
INSERT INTO plataforma.role_permissions(role_id,permission_code) SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p WHERE r.code='qa-parties-sql' AND p.code IN ('catalog.suppliers.read','catalog.suppliers.write') ON CONFLICT DO NOTHING;
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE a jsonb;BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong role';END IF;
 PERFORM set_config('app.current_operation','administration.proveedor.create',true);
 a:=administracion.party_write_v2('00008003-0000-0000-0000-000000000001','proveedor','create',NULL,'QA-LEGACY-CONTACT','QA legacy',NULL,'qa-legacy-contact','{}',NULL,NULL);
 PERFORM set_config('app.current_operation','administration.cliente.create',true);
 PERFORM administracion.party_write_v2('00008003-0000-0000-0000-000000000001','cliente','create',(a->>'id')::uuid,NULL,NULL,NULL,'qa-legacy-client','{}',NULL,NULL);
END $$;
RESET ROLE;
UPDATE catalogo.terceros SET datos_administrativos=NULL WHERE tenant_id='00008002-0000-0000-0000-000000000001' AND codigo='QA-LEGACY-CONTACT';
UPDATE catalogo.proveedores_catalogo SET contacto='{"phone":"QA-123","email":"legacy@example.invalid"}' WHERE tenant_id='00008002-0000-0000-0000-000000000001' AND codigo='QA-LEGACY-CONTACT';
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE a jsonb;BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong role';END IF;
 SELECT item INTO a FROM jsonb_array_elements(administracion.parties_read_v2('00008003-0000-0000-0000-000000000001','cliente',NULL,100)) item WHERE item->>'codigo'='QA-LEGACY-CONTACT';
 IF a->'datos_generales'->>'telefono'<>'QA-123' THEN RAISE EXCEPTION 'Legacy phone not projected';END IF;
END $$;
RESET ROLE;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM catalogo.terceros WHERE tenant_id='00008002-0000-0000-0000-000000000001' AND codigo='QA-LEGACY-CONTACT' AND datos_administrativos IS NOT NULL) THEN RAISE EXCEPTION 'Read must not backfill';END IF;
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
