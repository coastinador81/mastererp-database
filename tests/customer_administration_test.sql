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
DO $$
DECLARE a jsonb;b jsonb;v jsonb; id uuid;bad boolean; company uuid:='00008003-0000-0000-0000-000000000001';
details jsonb:='{"datos_generales":{"nombre_comercial":"QA cliente","pais_fiscal":"VE","tipo_identificacion":"DEMO","numero_identificacion":"QA-NO-FISCAL","email":"admin@example.invalid","telefono":"123","direccion":"Dirección administrativa QA"},"contactos":[],"condiciones":{"moneda":"VES","condicion_pago":"credito","plazo_pago_dias":"30","medio_pago":"transferencia"}}';
BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong role';END IF;
 PERFORM set_config('app.current_operation','administration.cliente.create',true);
 a:=administracion.party_write_v2(company,'cliente','create',NULL,'QA-CUSTOMER-ADMIN','QA customer',NULL,'qa-customer-admin',details,NULL,NULL);
 id:=(a->>'id')::uuid;
 IF a->'datos_generales'->>'telefono'<>'123' OR a->'condiciones'->>'plazo_pago_dias'<>'30' OR (a->>'catalog_version')::int<>0 THEN RAISE EXCEPTION 'Customer without supplier failed';END IF;
 b:=administracion.party_write_v2(company,'cliente','create',NULL,'QA-CUSTOMER-ADMIN','QA customer',NULL,'qa-customer-admin',details,NULL,NULL);
 IF NOT (b->>'replayed')::boolean OR b->>'id'<>a->>'id' THEN RAISE EXCEPTION 'Replay failed';END IF;
 PERFORM set_config('app.current_operation','administration.proveedor.create',true);
 b:=administracion.party_write_v2(company,'proveedor','create',id,NULL,NULL,NULL,'qa-customer-supplier','{}',NULL,NULL);
 IF b->'datos_generales'->>'email'<>'admin@example.invalid' OR b->>'id'<>a->>'id' THEN RAISE EXCEPTION 'Role common data not inherited';END IF;
 PERFORM set_config('app.current_operation','administration.cliente.update',true);
 a:=administracion.parties_read_v2(company,'cliente',id);
 a:=administracion.party_write_v2(company,'cliente','update',id,'QA-CUSTOMER-ADMIN-2','QA customer',(a->>'version')::bigint,NULL,'{"datos_generales":{"telefono":"456"},"contactos":[{"nombre":"QA contacto","email":"qa@example.invalid","principal":true}]}',NULL,(a->>'catalog_version')::bigint);
 v:=catalogo.proveedores_leer(id);
 IF v->>'code'<>'QA-CUSTOMER-ADMIN-2' OR v->'contact'->>'phone'<>'456' THEN RAISE EXCEPTION 'Catalog projection failed';END IF;
 IF (a->>'catalog_version')::bigint<>(b->>'catalog_version')::bigint+1 THEN RAISE EXCEPTION 'Double catalog version increment';END IF;
 PERFORM set_config('app.current_operation','catalog.suppliers.update',true);
 v:=catalogo.proveedor_actualizar(id,(v->>'version')::bigint,'{"contact":{"phone":"789"}}');
 a:=administracion.parties_read_v2(company,'cliente',id);
 IF a->'datos_generales'->>'telefono'<>'789' OR a->'datos_generales'->>'numero_identificacion'<>'QA-NO-FISCAL' THEN RAISE EXCEPTION 'Catalog overwrote common fiscal data';END IF;
 bad:=false;
 PERFORM set_config('app.current_operation','administration.cliente.update',true);
 BEGIN
  PERFORM administracion.party_write_v2(company,'cliente','update',id,'QA-CUSTOMER-ADMIN-2','QA customer',1,NULL,details,1,1);
 EXCEPTION WHEN serialization_failure THEN bad:=true;END;
 IF NOT bad THEN RAISE EXCEPTION 'Stale master accepted';END IF;
 bad:=false;
 BEGIN
  PERFORM administracion.party_write_v2(company,'cliente','update',id,'QA-CUSTOMER-ADMIN-2','QA customer',(a->>'version')::bigint,NULL,details,1,1);
 EXCEPTION WHEN serialization_failure THEN bad:=true;END;
 IF NOT bad THEN RAISE EXCEPTION 'Stale catalog accepted';END IF;
 bad:=false;
 BEGIN
  PERFORM administracion.party_write_v2('00008003-0000-0000-0000-000000000002','cliente','update',id,'QA-CUSTOMER-ADMIN-2','QA customer',(a->>'version')::bigint,NULL,'{}',NULL,NULL);
 EXCEPTION WHEN insufficient_privilege THEN bad:=true;END;
 IF NOT bad THEN RAISE EXCEPTION 'Foreign tenant accepted';END IF;
END $$;
RESET ROLE;
INSERT INTO ventas_digitales.cliente_identidades(tenant_id,empresa_id,cliente_id,user_id)
 SELECT tenant_id,'00008003-0000-0000-0000-000000000001',id,'00008001-0000-0000-0000-000000000001' FROM catalogo.terceros WHERE tenant_id='00008002-0000-0000-0000-000000000001' AND codigo='QA-CUSTOMER-ADMIN-2';
INSERT INTO ventas_digitales.cliente_perfiles(tenant_id,empresa_id,cliente_id,telefono)
 SELECT tenant_id,'00008003-0000-0000-0000-000000000001',id,'+584120000000' FROM catalogo.terceros WHERE tenant_id='00008002-0000-0000-0000-000000000001' AND codigo='QA-CUSTOMER-ADMIN-2';
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE a jsonb;BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong role';END IF;
 SELECT item INTO a FROM jsonb_array_elements(administracion.parties_read_v2('00008003-0000-0000-0000-000000000001','cliente',NULL,100)) item WHERE item->>'codigo'='QA-CUSTOMER-ADMIN-2';
 IF a->>'origen'<>'ecommerce' OR a->'contacto_ecommerce'->>'telefono'<>'+584120000000' OR a->'datos_generales'->>'telefono'<>'789' THEN RAISE EXCEPTION 'Channel data must stay separate';END IF;
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
