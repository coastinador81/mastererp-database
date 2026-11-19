BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-finance-supplier-code','Finance supplier code fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code) SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p WHERE r.code='qa-finance-supplier-code' AND p.code IN ('administration.parties.read','administration.parties.write','administration.purchases.read');
INSERT INTO plataforma.users(id,email,display_name) VALUES('00008001-0000-0000-0000-000000000078','qa-finance-supplier-code@example.invalid','Finance supplier code test');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00008002-0000-0000-0000-000000000078','qa-finance-supplier-code','qa-finance-supplier-code','Finance supplier code test','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00008002-0000-0000-0000-000000000078','00008001-0000-0000-0000-000000000078',id,'active' FROM plataforma.roles WHERE code='qa-finance-supplier-code';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00008002-0000-0000-0000-000000000078',id,'active' FROM plataforma.modules WHERE code='erp.finance';
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00008003-0000-0000-0000-000000000078','00008002-0000-0000-0000-000000000078','Finance supplier code test','US','USD','UTC');
SELECT set_config('app.current_user_id','00008001-0000-0000-0000-000000000078',true),
 set_config('app.current_tenant_id','00008002-0000-0000-0000-000000000078',true),
 set_config('app.current_operation','administration.proveedor.create',true),
 set_config('app.correlation_id','00008004-0000-0000-0000-000000000078',true);

SET LOCAL ROLE mastererp_app;
DO $$
DECLARE
 company constant uuid:='00008003-0000-0000-0000-000000000078';
 first_supplier jsonb;
 replay jsonb;
BEGIN
 IF administracion.proponer_codigo_proveedor(company) IS DISTINCT FROM 'PROV-0001'
 OR administracion.proponer_codigo_proveedor(company) IS DISTINCT FROM 'PROV-0001' THEN
  RAISE EXCEPTION 'Proposal consumed a code';
 END IF;
 first_supplier:=administracion.crear_proveedor_codigo_automatico(company,'First supplier','first','{}');
 IF first_supplier->>'codigo' IS DISTINCT FROM 'PROV-0001'
 OR administracion.proponer_codigo_proveedor(company) IS DISTINCT FROM 'PROV-0002' THEN
  RAISE EXCEPTION 'Assignment did not advance the proposal';
 END IF;
 BEGIN
  PERFORM administracion.crear_proveedor_codigo_automatico(company,'Rolled back supplier','rollback','{}');
  RAISE EXCEPTION 'Force rollback' USING ERRCODE='P0099';
 EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
 END;
 IF administracion.proponer_codigo_proveedor(company) IS DISTINCT FROM 'PROV-0002' THEN
  RAISE EXCEPTION 'Rollback consumed a code';
 END IF;
 PERFORM administracion.crear_proveedor_codigo_automatico(company,'Second supplier','second','{}');
 replay:=administracion.crear_proveedor_codigo_automatico(company,'First supplier','first','{}');
 IF replay->>'id' IS DISTINCT FROM first_supplier->>'id' OR replay->>'codigo' IS DISTINCT FROM 'PROV-0001'
 OR replay->>'replayed' IS DISTINCT FROM 'true'
 OR administracion.proponer_codigo_proveedor(company) IS DISTINCT FROM 'PROV-0003' THEN
  RAISE EXCEPTION 'Replay reassigned a code';
 END IF;
 IF NOT EXISTS(
  SELECT FROM jsonb_array_elements(administracion.purchase_options(company)->'proveedores') AS supplier
  WHERE supplier->>'id'=first_supplier->>'id' AND supplier->>'codigo'='PROV-0001'
 ) THEN RAISE EXCEPTION 'Supplier missing from purchase options'; END IF;
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
