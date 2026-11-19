BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-company-fiscal','Company fiscal profile test');
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.permission_code FROM plataforma.roles r CROSS JOIN
 (VALUES('digital_sales.ecommerce.read'),('digital_sales.ecommerce.write')) p(permission_code)
 WHERE r.code='qa-company-fiscal';
INSERT INTO plataforma.users(id,email,display_name) VALUES('00007701-0000-0000-0000-000000000001','qa-company-fiscal@example.invalid','Fiscal test');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00007702-0000-0000-0000-000000000001','qa-company-fiscal','qa-company-fiscal','Fiscal test','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00007702-0000-0000-0000-000000000001','00007701-0000-0000-0000-000000000001',id,'active' FROM plataforma.roles WHERE code='qa-company-fiscal';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00007702-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code='digital_sales.ecommerce';
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone,settings)
 VALUES('00007703-0000-0000-0000-000000000001','00007702-0000-0000-0000-000000000001','Before','VE','USD','America/Caracas','{"secret":"preserved"}');
SET LOCAL ROLE mastererp_app;
SELECT set_config('app.current_user_id','00007701-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','00007702-0000-0000-0000-000000000001',true),
 set_config('app.current_operation','digital_sales.ecommerce.configure',true);
DO $$ DECLARE result jsonb;caught boolean:=false;BEGIN
 result:=organizacion.company_fiscal_profile_update('00007703-0000-0000-0000-000000000001',
  '{"legal_name":"Empresa Legal C.A.","trade_name":"Empresa","tax_identifier":"j-123","address":"Caracas","phone":"0212","email":"facturas@example.com","logo_url":"https://example.com/logo.png","primary_color":"#0758b3"}');
 IF result->>'legal_name'<>'Empresa Legal C.A.' OR result->>'tax_identifier'<>'J-123' OR result->>'address'<>'Caracas' THEN
  RAISE EXCEPTION 'Fiscal profile did not round trip';END IF;
 IF (SELECT settings->>'secret' FROM organizacion.companies WHERE id='00007703-0000-0000-0000-000000000001')<>'preserved' THEN
  RAISE EXCEPTION 'Unrelated company setting was overwritten';END IF;
 BEGIN PERFORM organizacion.company_fiscal_profile_read('00007703-0000-0000-0000-000000000099');EXCEPTION WHEN insufficient_privilege OR no_data_found THEN caught:=true;END;
 IF NOT caught THEN RAISE EXCEPTION 'Foreign company profile exposed';END IF;
END $$;
RESET ROLE;
ROLLBACK;
