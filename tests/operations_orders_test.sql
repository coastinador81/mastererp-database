BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-orders-sql','Orders SQL fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='qa-orders-sql' AND p.code IN ('operations.orders.read','operations.orders.write');
INSERT INTO plataforma.users(id,email,display_name) VALUES('00009001-0000-0000-0000-000000000001','qa-orders@example.invalid','Orders test');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00009002-0000-0000-0000-000000000001','qa-orders','qa-orders','Orders','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00009002-0000-0000-0000-000000000001','00009001-0000-0000-0000-000000000001',id,'active' FROM plataforma.roles WHERE code='qa-orders-sql';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00009002-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code='erp.operations';
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00009003-0000-0000-0000-000000000001','00009002-0000-0000-0000-000000000001','Orders','US','USD','UTC');
INSERT INTO catalogo.monedas(codigo,nombre,decimales) VALUES('USD','US dollar',2) ON CONFLICT DO NOTHING;
INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code,status)
 VALUES('00009004-0000-0000-0000-000000000001','00009002-0000-0000-0000-000000000001','00009003-0000-0000-0000-000000000001','MAIN','Main','office','US','active');
INSERT INTO catalogo.terceros(id,tenant_id,codigo,nombre) VALUES('00009005-0000-0000-0000-000000000001','00009002-0000-0000-0000-000000000001','CUSTOMER','Customer');
INSERT INTO catalogo.roles_tercero VALUES('00009002-0000-0000-0000-000000000001','00009005-0000-0000-0000-000000000001','cliente');
INSERT INTO catalogo.productos(id,tenant_id,codigo,nombre) VALUES('00009006-0000-0000-0000-000000000001','00009002-0000-0000-0000-000000000001','PRODUCT','Product');
INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,request_tenant_id,request_fingerprint)
 VALUES('orders-test-key','00009001-0000-0000-0000-000000000001','operations.orders.create','00009002-0000-0000-0000-000000000001',repeat('a',64));
SELECT set_config('app.current_user_id','00009001-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','00009002-0000-0000-0000-000000000001',true),
 set_config('app.current_company_id','00009003-0000-0000-0000-000000000001',true),
 set_config('app.current_operation','operations.orders.transition',true),
 set_config('app.correlation_id','00009007-0000-0000-0000-000000000001',true);
INSERT INTO operaciones.pedidos(id,tenant_id,empresa_id,sucursal_id,cliente_id,numero,estado,moneda,subtotal,
 cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,reserva_inventario_ref,idempotency_key)
VALUES('00009008-0000-0000-0000-000000000001','00009002-0000-0000-0000-000000000001','00009003-0000-0000-0000-000000000001',
 '00009004-0000-0000-0000-000000000001','00009005-0000-0000-0000-000000000001','ORDER-1','PENDING','USD',10,
 '{"name":"Customer"}','{"address":"Here"}','{"method":"cash","status":"PENDING_COLLECTION"}','slot','realtime','reservation','orders-test-key');
INSERT INTO operaciones.pedido_lineas(tenant_id,empresa_id,pedido_id,posicion,producto_id,producto_nombre,cantidad,precio_unitario)
VALUES('00009002-0000-0000-0000-000000000001','00009003-0000-0000-0000-000000000001','00009008-0000-0000-0000-000000000001',1,
 '00009006-0000-0000-0000-000000000001','Product',2,5);
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE item jsonb; caught boolean:=false; BEGIN
 item:=operaciones.pedidos_leer('00009003-0000-0000-0000-000000000001','00009008-0000-0000-0000-000000000001');
 IF item->>'status'<>'PENDING' OR item->>'total'<>'10' OR jsonb_array_length(item->'items')<>1 THEN RAISE EXCEPTION 'Order read mismatch'; END IF;
 item:=operaciones.pedido_transicionar('00009003-0000-0000-0000-000000000001','00009008-0000-0000-0000-000000000001',1,'CONFIRMED','ORDER_CONFIRMED');
 IF item->>'status'<>'CONFIRMED' OR (item->>'version')::int<>2 THEN RAISE EXCEPTION 'Transition mismatch'; END IF;
 IF jsonb_array_length(item->'history')<>1
 OR item->'history'->0->>'status'<>'CONFIRMED'
 OR item->'history'->0->>'reason'<>'ORDER_CONFIRMED'
 OR item->'history'->0->>'actor_name'<>'Orders test'
 THEN RAISE EXCEPTION 'Order history mismatch'; END IF;
 PERFORM set_config('app.current_operation','operations.orders.notes.create',true);
 item:=operaciones.pedido_nota_crear('00009003-0000-0000-0000-000000000001','00009008-0000-0000-0000-000000000001','Contactar al cliente','orders-note-key');
 IF item->>'note'<>'Contactar al cliente' OR item->>'actor_name'<>'Orders test'
 OR jsonb_array_length(operaciones.pedido_notas_leer('00009003-0000-0000-0000-000000000001','00009008-0000-0000-0000-000000000001'))<>1
 THEN RAISE EXCEPTION 'Order note mismatch'; END IF;
 IF operaciones.pedido_nota_crear('00009003-0000-0000-0000-000000000001','00009008-0000-0000-0000-000000000001','Contactar al cliente','orders-note-key')->>'id'<>item->>'id'
 THEN RAISE EXCEPTION 'Order note idempotency mismatch'; END IF;
 PERFORM set_config('app.current_operation','operations.orders.transition',true);
 BEGIN PERFORM operaciones.pedido_transicionar('00009003-0000-0000-0000-000000000001','00009008-0000-0000-0000-000000000001',1,'PREPARING','START');
 EXCEPTION WHEN serialization_failure THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Stale version accepted'; END IF;
 PERFORM set_config('app.current_operation','operations.orders.create',true);
 item:=operaciones.pedido_crear('00009003-0000-0000-0000-000000000001','00009004-0000-0000-0000-000000000001',
  '00009005-0000-0000-0000-000000000001','USD','[{"product_id":"00009006-0000-0000-0000-000000000001","product_name":"Product","quantity":2,"unit_price":5}]',
  '{"name":"Customer"}','{"address":"Here"}','{"method":"cash","status":"PENDING_COLLECTION"}',
  'slot','realtime','reservation-2',1,NULL,'orders-created-key');
 IF item->>'status'<>'PENDING' OR item->>'total'<>'11' THEN RAISE EXCEPTION 'Order create mismatch'; END IF;
 IF operaciones.pedido_crear('00009003-0000-0000-0000-000000000001','00009004-0000-0000-0000-000000000001',
  '00009005-0000-0000-0000-000000000001','USD','[{"product_id":"00009006-0000-0000-0000-000000000001","product_name":"Product","quantity":2,"unit_price":5}]',
  '{"name":"Customer"}','{"address":"Here"}','{"method":"cash","status":"PENDING_COLLECTION"}',
  'slot','realtime','reservation-2',1,NULL,'orders-created-key')->>'id'<>item->>'id' THEN RAISE EXCEPTION 'Order idempotency mismatch'; END IF;
 IF has_table_privilege('mastererp_app','operaciones.pedidos','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Direct DML leaked'; END IF;
END $$;
ROLLBACK;
