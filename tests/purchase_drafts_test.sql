BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-purchases-sql','Parties SQL fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code) SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p WHERE r.code='qa-purchases-sql' AND p.code IN ('administration.parties.read','administration.parties.write','administration.purchases.read','administration.purchases.write');
INSERT INTO plataforma.users(id,email,display_name) VALUES('00008701-0000-0000-0000-000000000001','qa-purchases-local@example.invalid','Parties test');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00008702-0000-0000-0000-000000000001','qa-purchases-local','qa-purchases-local','Parties test','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00008702-0000-0000-0000-000000000001','00008701-0000-0000-0000-000000000001',id,'active' FROM plataforma.roles WHERE code='qa-purchases-sql';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00008702-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code='erp.finance';
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00008703-0000-0000-0000-000000000001','00008702-0000-0000-0000-000000000001','Parties test','US','USD','UTC');
SELECT set_config('app.current_user_id','00008701-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','00008702-0000-0000-0000-000000000001',true),
 set_config('app.current_operation','administration.cliente.create',true),
 set_config('app.correlation_id','00008704-0000-0000-0000-000000000001',true);

INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00008702-0000-0000-0000-000000000002','qa-purchase-details-foreign','qa-purchase-details-foreign','Foreign details fixture','active');
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone) VALUES
 ('00008703-0000-0000-0000-000000000002','00008702-0000-0000-0000-000000000002','Foreign details fixture','US','USD','UTC'),
 ('00008703-0000-0000-0000-000000000003','00008702-0000-0000-0000-000000000001','Second details fixture','US','USD','UTC');
INSERT INTO plataforma.role_permissions(role_id,permission_code) SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p WHERE r.code='qa-purchases-sql' AND p.code IN ('catalog.suppliers.read','catalog.suppliers.write');
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status) SELECT '00008702-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code='erp.catalog';
SET LOCAL ROLE mastererp_app;
DO $$
DECLARE supplier jsonb; request jsonb; replay jsonb; purchase_order jsonb; invoice jsonb; updated jsonb;
 body jsonb; caught boolean; company uuid:='00008703-0000-0000-0000-000000000001';
BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 PERFORM set_config('app.current_operation','administration.proveedor.create',true);
 supplier:=administracion.party_write_v2(company,'proveedor','create',NULL,'qa-purchase-supplier','QA purchase supplier',NULL,'qa-purchase-supplier');
 body:=jsonb_build_object('proveedor_id',supplier->>'id','fecha','2026-11-04','moneda','USD','tipo_cambio','1',
 'cambio_fecha','2026-11-04','cambio_fuente','misma moneda','numero','QA-PURCHASE-REQUEST',
 'lineas',jsonb_build_array(jsonb_build_object('descripcion','QA service','cantidad','2','precio_unitario','12.35')));
 PERFORM set_config('app.current_operation','administracion.documento.solicitud_compra.crear',true);
 request:=administracion.purchase_write(company,'solicitud_compra',NULL,NULL,'qa-purchase-create',body);
 IF (request->>'total')::numeric<>24.70 OR jsonb_array_length(request->'lineas')<>1 THEN RAISE EXCEPTION 'Purchase persistence/precision failed'; END IF;
 replay:=administracion.purchase_write(company,'solicitud_compra',NULL,NULL,'qa-purchase-create',body);
 IF replay->>'id'<>request->>'id' OR (replay->>'replayed')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'Purchase replay failed'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.purchase_write(company,'solicitud_compra',NULL,NULL,'qa-purchase-create',body||'{"numero":"DIFFERENT"}');
 EXCEPTION WHEN unique_violation THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Different payload replay accepted'; END IF;
 PERFORM set_config('app.current_operation','administracion.documento.solicitud_compra.actualizar',true);
 updated:=administracion.purchase_write(company,'solicitud_compra',(request->>'id')::uuid,1,NULL,body||'{"numero":"QA-PURCHASE-EDITED"}');
 IF (updated->>'version')::bigint<>2 THEN RAISE EXCEPTION 'Purchase update failed'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.purchase_write(company,'solicitud_compra',(request->>'id')::uuid,1,NULL,body);
 EXCEPTION WHEN serialization_failure THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Stale purchase accepted'; END IF;
 PERFORM set_config('app.current_operation','administracion.documento.orden_compra.crear',true);
 body:=body||jsonb_build_object('origen_id',request->>'id','numero','QA-PURCHASE-ORDER');
 purchase_order:=administracion.purchase_write(company,'orden_compra',NULL,NULL,'qa-purchase-order',body);
 caught:=false;
 BEGIN PERFORM administracion.purchase_write(company,'orden_compra',NULL,NULL,'qa-purchase-order-duplicate',body||'{"numero":"OTHER"}');
 EXCEPTION WHEN unique_violation THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Second order accepted'; END IF;
 PERFORM set_config('app.current_operation','administracion.documento.solicitud_compra.actualizar',true);
 caught:=false;
 BEGIN PERFORM administracion.purchase_write(company,'solicitud_compra',(request->>'id')::uuid,2,NULL,body-'origen_id');
 EXCEPTION WHEN object_not_in_prerequisite_state THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Used request edited'; END IF;
 PERFORM set_config('app.current_operation','administracion.documento.factura_proveedor.crear',true);
 invoice:=administracion.purchase_write(company,'factura_proveedor',NULL,NULL,'qa-purchase-invoice',body||jsonb_build_object('origen_id',purchase_order->>'id','numero','QA-INVOICE'));
 IF invoice->>'origen_id'<>purchase_order->>'id' THEN RAISE EXCEPTION 'Invoice source lost'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.purchase_read('00008703-0000-0000-0000-000000000002','solicitud_compra');
 EXCEPTION WHEN insufficient_privilege THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Foreign tenant company read'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.purchase_read('00008703-0000-0000-0000-000000000003','solicitud_compra',(request->>'id')::uuid);
 EXCEPTION WHEN no_data_found THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Foreign company document read'; END IF;
 PERFORM set_config('app.current_operation','administracion.documento.orden_compra.crear',true);
 caught:=false;
 BEGIN PERFORM administracion.purchase_write('00008703-0000-0000-0000-000000000003','orden_compra',NULL,NULL,'qa-cross-company',body);
 EXCEPTION WHEN invalid_parameter_value THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Cross-company source accepted'; END IF;
 IF has_table_privilege('mastererp_app','administracion.documentos','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Direct DML leaked'; END IF;
 PERFORM set_config('app.current_tenant_id','',true);caught:=false;
 BEGIN PERFORM administracion.purchase_read(company,'solicitud_compra');
 EXCEPTION WHEN insufficient_privilege THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Missing context accepted'; END IF;
END $$;
-- A rollback-only test must still fire the constraints enforced by a real COMMIT.
SELECT set_config('app.current_tenant_id','00008702-0000-0000-0000-000000000001',true);
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
RESET ROLE;
UPDATE plataforma.user_tenants SET permissions_override='{"administration.purchases.write":false}'::jsonb
 WHERE tenant_id='00008702-0000-0000-0000-000000000001';
SELECT set_config('app.current_tenant_id','00008702-0000-0000-0000-000000000001',true);
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE caught boolean:=false; BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 BEGIN PERFORM administracion.purchase_write('00008703-0000-0000-0000-000000000001','solicitud_compra',NULL,NULL,'denied','{}');
 EXCEPTION WHEN insufficient_privilege THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Explicit deny ignored'; END IF;
END $$;
RESET ROLE;
UPDATE plataforma.tenant_modules SET status='suspended' WHERE tenant_id='00008702-0000-0000-0000-000000000001';
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE caught boolean:=false; BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 BEGIN PERFORM administracion.purchase_read('00008703-0000-0000-0000-000000000001','solicitud_compra');
 EXCEPTION WHEN insufficient_privilege THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Disabled module ignored'; END IF;
END $$;
ROLLBACK;
