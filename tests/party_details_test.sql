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
SET LOCAL ROLE mastererp_app;
DO $$
DECLARE first jsonb; replay jsonb; current_data jsonb; other_company jsonb; third uuid; caught boolean; legacy jsonb;
 details jsonb:='{"datos_generales":{"nombre_comercial":"QA ficticio","pais_fiscal":"VE","tipo_identificacion":"DEMO","numero_identificacion":"QA-NO-FISCAL","email":"qa-details@example.invalid","direccion":"Dirección ficticia"},"contactos":[{"nombre":"Contacto QA","email":"contact@example.invalid","principal":true}],"condiciones":{"moneda":"VES","condicion_pago":"credito","medio_pago":"transferencia","plazo_pago_dias":"30","descuento_pronto_pago":"3","plazo_pronto_pago_dias":"5"}}';
BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 PERFORM set_config('app.current_operation','administration.proveedor.create',true);
 first:=administracion.party_write_v2('00008003-0000-0000-0000-000000000001','proveedor','create',NULL,'qa-full-details','QA full details',NULL,'full-details',details,NULL);
 third:=(first->>'id')::uuid;
 IF first->'datos_generales'->>'email'<>'qa-details@example.invalid' OR jsonb_array_length(first->'contactos')<>1
 OR (first->'condiciones'->>'plazo_pago_dias')::int<>30 OR (first->'condiciones'->>'descuento_pronto_pago')::numeric<>3 THEN RAISE EXCEPTION 'Details not persisted'; END IF;
 replay:=administracion.party_write_v2('00008003-0000-0000-0000-000000000001','proveedor','create',NULL,'qa-full-details','QA full details',NULL,'full-details',details,NULL);
 IF replay->>'id'<>first->>'id' OR (replay->>'replayed')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'Full replay failed'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.party_write_v2('00008003-0000-0000-0000-000000000001','proveedor','create',NULL,'qa-full-details','QA full details',NULL,'full-details',jsonb_set(details,'{datos_generales,email}','"changed@example.invalid"'),NULL);
 EXCEPTION WHEN unique_violation THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Extended idempotency mismatch accepted'; END IF;
 other_company:=administracion.party_write_v2('00008003-0000-0000-0000-000000000003','proveedor','create',third,NULL,NULL,NULL,'second-company','{"condiciones":{"plazo_pago_dias":"60"}}',NULL);
 IF other_company->>'id'<>first->>'id' OR (other_company->'condiciones'->>'plazo_pago_dias')::int<>60 THEN RAISE EXCEPTION 'Company profile not reused'; END IF;
 PERFORM set_config('app.current_operation','administration.proveedor.update',true);
 current_data:=administracion.party_write_v2('00008003-0000-0000-0000-000000000001','proveedor','update',third,'qa-full-details','QA changed',(first->>'version')::bigint,NULL,jsonb_set(details,'{datos_generales,email}','"updated@example.invalid"'),(first->>'profile_version')::bigint,(first->>'catalog_version')::bigint);
 IF current_data->'datos_generales'->>'email'<>'updated@example.invalid' OR (current_data->>'version')::bigint<>(first->>'version')::bigint+1 THEN RAISE EXCEPTION 'Update not persisted'; END IF;
 other_company:=administracion.parties_read_v2('00008003-0000-0000-0000-000000000003','proveedor',third);
 IF other_company->'datos_generales'->>'email'<>'updated@example.invalid' OR (other_company->'condiciones'->>'plazo_pago_dias')::int<>60 THEN RAISE EXCEPTION 'Shared master/company separation failed'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.party_write_v2('00008003-0000-0000-0000-000000000001','proveedor','update',third,'qa-full-details','QA stale',(first->>'version')::bigint,NULL,details,(first->>'profile_version')::bigint,(first->>'catalog_version')::bigint);
 EXCEPTION WHEN serialization_failure THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Stale master version accepted'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.party_write_v2('00008003-0000-0000-0000-000000000001','proveedor','update',third,'qa-full-details','QA stale profile',(current_data->>'version')::bigint,NULL,details,(first->>'profile_version')::bigint,(current_data->>'catalog_version')::bigint);
 EXCEPTION WHEN serialization_failure THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Stale company profile accepted'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.party_write_v2('00008003-0000-0000-0000-000000000001','proveedor','update',third,'qa-full-details','QA invalid',(current_data->>'version')::bigint,NULL,'{"contactos":[{"principal":true},{"principal":true}]}',NULL);
 EXCEPTION WHEN invalid_parameter_value THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Multiple principal contacts accepted'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.parties_read_v2('00008003-0000-0000-0000-000000000002','proveedor');
 EXCEPTION WHEN insufficient_privilege THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Foreign company accepted'; END IF;
 IF catalogo.proveedores_leer(third)->'contact'->>'email'<>'updated@example.invalid' THEN RAISE EXCEPTION 'Catalog and Finance supplier diverged'; END IF;
 PERFORM set_config('app.current_operation','catalog.suppliers.update',true);
 PERFORM catalogo.proveedor_actualizar(third,(current_data->>'catalog_version')::bigint,'{"status":"ACTIVE"}');
 PERFORM set_config('app.current_operation','administration.proveedor.update',true);caught:=false;
 BEGIN PERFORM administracion.party_write_v2('00008003-0000-0000-0000-000000000001','proveedor','update',third,'qa-full-details','QA stale catalog',(current_data->>'version')::bigint,NULL,details,(current_data->>'profile_version')::bigint,(current_data->>'catalog_version')::bigint);
 EXCEPTION WHEN serialization_failure THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Concurrent Catalog change ignored'; END IF;
 -- Existing callers and stored v1 idempotency responses remain compatible.
 PERFORM set_config('app.current_operation','administration.proveedor.create',true);
 legacy:=administracion.party_write('00008003-0000-0000-0000-000000000001','proveedor','create',NULL,'qa-details-legacy','Legacy',NULL,'legacy-replay');
 replay:=administracion.party_write_v2('00008003-0000-0000-0000-000000000001','proveedor','create',NULL,'qa-details-legacy','Legacy',NULL,'legacy-replay');
 IF replay->>'id'<>legacy->>'id' OR (replay->>'replayed')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'v1 replay compatibility lost'; END IF;
 IF has_table_privilege('mastererp_app','catalogo.terceros','INSERT,UPDATE,DELETE') OR has_table_privilege('mastererp_app','administracion.condiciones_comerciales','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Direct DML leaked'; END IF;
 PERFORM set_config('app.current_tenant_id','',true); caught:=false;
 BEGIN PERFORM administracion.parties_read_v2('00008003-0000-0000-0000-000000000001','proveedor');
 EXCEPTION WHEN insufficient_privilege THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Missing tenant accepted'; END IF;
END $$;
ROLLBACK;
