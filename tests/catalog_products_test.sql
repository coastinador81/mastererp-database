BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-products-sql','Products SQL fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='qa-products-sql' AND p.code IN ('catalog.products.read','catalog.products.write');
INSERT INTO plataforma.users(id,email,display_name) VALUES('00008001-0000-0000-0000-000000000001','qa-products@example.invalid','Products test');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00008002-0000-0000-0000-000000000001','qa-products','qa-products','Products','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00008002-0000-0000-0000-000000000001','00008001-0000-0000-0000-000000000001',id,'active' FROM plataforma.roles WHERE code='qa-products-sql';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00008002-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code='erp.catalog';
SELECT set_config('app.current_user_id','00008001-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','00008002-0000-0000-0000-000000000001',true),
 set_config('app.current_operation','catalog.products.create',true),
 set_config('app.correlation_id','00008003-0000-0000-0000-000000000001',true);
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE item jsonb; same jsonb; caught boolean:=false; BEGIN
 item:=catalogo.producto_crear('Harina de maíz 1kg','Harina precocida',2.5,'ACTIVE','alimentos','/images/harina.jpg','{"sku":"HAR-1"}',NULL,'products-test-key');
 IF item->>'name'<>'Harina de maíz 1kg' OR item->>'price'<>'2.5' OR item->>'status'<>'ACTIVE' THEN RAISE EXCEPTION 'Product create mismatch'; END IF;
 same:=catalogo.producto_crear('Harina de maíz 1kg','Harina precocida',2.5,'ACTIVE','alimentos','/images/harina.jpg','{"sku":"HAR-1"}',NULL,'products-test-key');
 IF same->>'id'<>item->>'id' THEN RAISE EXCEPTION 'Product replay mismatch'; END IF;
 PERFORM set_config('app.current_operation','catalog.products.update',true);
 item:=catalogo.producto_actualizar((item->>'id')::uuid,1,'{"price":3,"status":"INACTIVE"}');
 IF item->>'price'<>'3' OR item->>'status'<>'INACTIVE' OR (item->>'version')::int<>2 THEN RAISE EXCEPTION 'Product update mismatch'; END IF;
 BEGIN PERFORM catalogo.producto_actualizar((item->>'id')::uuid,1,'{"name":"stale"}'); EXCEPTION WHEN serialization_failure THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Stale product update accepted'; END IF;
 IF jsonb_array_length(catalogo.productos_leer(NULL,'INACTIVE','Harina',50))<>1 THEN RAISE EXCEPTION 'Product list mismatch'; END IF;
 IF has_table_privilege('mastererp_app','catalogo.productos','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Direct product DML leaked'; END IF;
END $$;
ROLLBACK;
