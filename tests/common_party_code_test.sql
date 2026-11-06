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
DECLARE a jsonb;b jsonb;c jsonb; sid uuid; before_version bigint; failed boolean;
company uuid:='00008003-0000-0000-0000-000000000001';
BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 PERFORM set_config('app.current_operation','administration.proveedor.create',true);
 a:=administracion.party_write_v2(company,'proveedor','create',NULL,'QA-CODE-A','QA common code',NULL,'qa-common-code-a','{}',NULL,NULL);
 sid:=(a->>'id')::uuid;
 b:=administracion.party_write_v2(company,'proveedor','create',NULL,'QA-CODE-A','QA common code',NULL,'qa-common-code-a','{}',NULL,NULL);
 IF b->>'id'<>a->>'id' OR NOT (b->>'replayed')::boolean THEN RAISE EXCEPTION 'Replay failed';END IF;
 PERFORM set_config('app.current_operation','administration.cliente.create',true);
 PERFORM administracion.party_write_v2(company,'cliente','create',sid,NULL,NULL,NULL,'qa-common-client','{}',NULL,NULL);
 PERFORM set_config('app.current_operation','administration.cliente.update',true);
 a:=administracion.party_write_v2(company,'cliente','update',sid,'QA-CODE-B','QA common code',(a->>'version')::bigint,NULL,'{}',NULL,NULL);
 c:=catalogo.proveedores_leer(sid);
 IF c->>'code'<>'QA-CODE-B' OR (c->>'version')::bigint<>2 THEN RAISE EXCEPTION 'Double role sync failed';END IF;
 PERFORM set_config('app.current_operation','administration.proveedor.update',true);
 a:=administracion.party_write_v2(company,'proveedor','update',sid,'QA-CODE-C','QA common code',(a->>'version')::bigint,NULL,'{"contactos":[{"nombre":"QA contact","principal":false}]}',NULL,2);
 c:=catalogo.proveedores_leer(sid);
 IF c->>'code'<>'QA-CODE-C' OR (c->>'version')::bigint<>3 THEN RAISE EXCEPTION 'Redundant version increment'; END IF;
 -- A later error must roll back both code updates and versions.
 before_version:=(a->>'version')::bigint;
 BEGIN
  PERFORM administracion.party_write_v2(company,'proveedor','update',sid,'QA-CODE-ROLLBACK','QA common code',before_version,NULL,'{}',NULL,NULL);
  RAISE EXCEPTION 'Forced later failure' USING ERRCODE='P0099';
 EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;END;
 c:=catalogo.proveedores_leer(sid);
 IF c->>'code'<>'QA-CODE-C' OR (c->>'version')::bigint<>3 THEN RAISE EXCEPTION 'Rollback incomplete';END IF;
 PERFORM set_config('app.current_operation','administration.proveedor.create',true);
 b:=administracion.party_write_v2(company,'proveedor','create',NULL,'QA-CODE-OCCUPIED','QA other',NULL,'qa-common-other','{}',NULL,NULL);
 PERFORM set_config('app.current_operation','administration.proveedor.update',true);
 failed:=false;
 BEGIN
  PERFORM administracion.party_write_v2(company,'proveedor','update',sid,'QA-CODE-OCCUPIED','QA common code',before_version,NULL,'{}',NULL,NULL);
 EXCEPTION WHEN unique_violation THEN failed:=true;END;
 IF NOT failed OR catalogo.proveedores_leer(sid)->>'code'<>'QA-CODE-C' THEN RAISE EXCEPTION 'Collision rollback failed';END IF;
 failed:=false;
 BEGIN
  PERFORM administracion.party_write_v2(company,'proveedor','update',sid,'QA-CODE-STALE','QA common code',1,NULL,'{}',NULL,NULL);
 EXCEPTION WHEN serialization_failure THEN failed:=true;END;
 IF NOT failed THEN RAISE EXCEPTION 'Stale update accepted';END IF;
END $$;
-- Deliberately divergent synthetic fixture: only disposable test setup uses admin DML.
RESET ROLE;
UPDATE catalogo.proveedores_catalogo SET codigo='QA-COPY-ONLY' WHERE tenant_id='00008002-0000-0000-0000-000000000001' AND codigo='QA-CODE-OCCUPIED';
SET LOCAL ROLE mastererp_app;
DO $$
DECLARE a jsonb; failed boolean:=false; company uuid:='00008003-0000-0000-0000-000000000001';
BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role';END IF;
 SELECT item INTO a FROM jsonb_array_elements(administracion.parties_read_v2(company,'proveedor',NULL,100,NULL)) item WHERE item->>'codigo'='QA-CODE-C';
 PERFORM set_config('app.current_operation','administration.proveedor.update',true);
 BEGIN
  PERFORM administracion.party_write_v2(company,'proveedor','update',(a->>'id')::uuid,'QA-COPY-ONLY','QA common code',(a->>'version')::bigint,NULL,'{}',NULL,NULL);
 EXCEPTION WHEN unique_violation THEN failed:=true;END;
 IF NOT failed OR catalogo.proveedores_leer((a->>'id')::uuid)->>'code'<>'QA-CODE-C' THEN RAISE EXCEPTION 'Copy collision rollback failed';END IF;
 IF administracion.parties_read_v2(company,'proveedor',(a->>'id')::uuid)->>'version'<>a->>'version' THEN RAISE EXCEPTION 'Partial master version';END IF;
END $$;
RESET ROLE;
UPDATE catalogo.proveedores_catalogo SET codigo='QA-LEGACY-ALIAS'
 WHERE tenant_id='00008002-0000-0000-0000-000000000001' AND codigo='QA-CODE-C';
SET LOCAL ROLE mastererp_app;
DO $$
DECLARE a jsonb; failed boolean:=false;
company uuid:='00008003-0000-0000-0000-000000000001';
BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role';END IF;
 a:=administracion.parties_read_v2(company,'proveedor',NULL,100,NULL)->0;
 -- Select by fixture code rather than relying on UUID ordering.
 SELECT item INTO a FROM jsonb_array_elements(administracion.parties_read_v2(company,'proveedor',NULL,100,NULL)) item WHERE item->>'codigo'='QA-CODE-C';
 PERFORM set_config('app.current_operation','administration.proveedor.update',true);
 -- The divergent fixture itself must reject any attempted code replacement.
 BEGIN
  PERFORM administracion.party_write_v2(company,'proveedor','update',(a->>'id')::uuid,'QA-COPY-ONLY','QA common code',(a->>'version')::bigint,NULL,'{}',NULL,NULL);
 EXCEPTION WHEN unique_violation THEN failed:=true;END;
 IF NOT failed THEN RAISE EXCEPTION 'Divergence not rejected';END IF;
 failed:=false;
 PERFORM set_config('app.current_operation','administration.cliente.update',true);
 BEGIN
  PERFORM administracion.party_write_v2(company,'cliente','update',(a->>'id')::uuid,'QA-NEW','QA common code',(a->>'version')::bigint,NULL,'{}',NULL,NULL);
 EXCEPTION WHEN unique_violation THEN failed:=true;END;
 IF NOT failed OR catalogo.proveedores_leer((a->>'id')::uuid)->>'code'<>'QA-LEGACY-ALIAS' THEN RAISE EXCEPTION 'Alias overwritten';END IF;
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
