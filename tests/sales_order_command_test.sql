BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-sales-046-sql','Orders SQL fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='qa-sales-046-sql' AND p.code IN ('operations.orders.read','operations.orders.write','administration.sales.write','administration.read');
INSERT INTO plataforma.users(id,email,display_name) VALUES('00014601-0000-0000-0000-000000000001','qa-sales-046@example.invalid','Orders test');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00014602-0000-0000-0000-000000000001','qa-sales-046','qa-sales-046','Orders','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00014602-0000-0000-0000-000000000001','00014601-0000-0000-0000-000000000001',id,'active' FROM plataforma.roles WHERE code='qa-sales-046-sql';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00014602-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code IN ('erp.operations','erp.finance');
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00014603-0000-0000-0000-000000000001','00014602-0000-0000-0000-000000000001','Orders','US','USD','UTC');
INSERT INTO catalogo.monedas(codigo,nombre,decimales) VALUES('USD','US dollar',2) ON CONFLICT DO NOTHING;
INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code,status)
 VALUES('00014604-0000-0000-0000-000000000001','00014602-0000-0000-0000-000000000001','00014603-0000-0000-0000-000000000001','MAIN','Main','office','US','active');
INSERT INTO catalogo.terceros(id,tenant_id,codigo,nombre) VALUES('00014605-0000-0000-0000-000000000001','00014602-0000-0000-0000-000000000001','CUSTOMER','Customer');
INSERT INTO catalogo.roles_tercero VALUES('00014602-0000-0000-0000-000000000001','00014605-0000-0000-0000-000000000001','cliente');
INSERT INTO catalogo.productos(id,tenant_id,codigo,nombre) VALUES('00014606-0000-0000-0000-000000000001','00014602-0000-0000-0000-000000000001','PRODUCT','Product');
INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,request_tenant_id,request_fingerprint)
 VALUES('sales-046-order-key','00014601-0000-0000-0000-000000000001','operations.orders.create','00014602-0000-0000-0000-000000000001',repeat('a',64));
SELECT set_config('app.current_user_id','00014601-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','00014602-0000-0000-0000-000000000001',true),
 set_config('app.current_company_id','00014603-0000-0000-0000-000000000001',true),
 set_config('app.current_operation','operations.orders.transition',true),
 set_config('app.correlation_id','00014607-0000-0000-0000-000000000001',true);
INSERT INTO operaciones.pedidos(id,tenant_id,empresa_id,sucursal_id,cliente_id,numero,estado,moneda,subtotal,
 cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,reserva_inventario_ref,idempotency_key)
VALUES('00014608-0000-0000-0000-000000000001','00014602-0000-0000-0000-000000000001','00014603-0000-0000-0000-000000000001',
 '00014604-0000-0000-0000-000000000001','00014605-0000-0000-0000-000000000001','ORDER-1','PENDING','USD',10,
 '{"name":"Customer"}','{"address":"Here"}','{"method":"cash","status":"PENDING_COLLECTION"}','slot','realtime','reservation','sales-046-order-key');
INSERT INTO operaciones.pedido_lineas(tenant_id,empresa_id,pedido_id,posicion,producto_id,producto_nombre,cantidad,precio_unitario)
VALUES('00014602-0000-0000-0000-000000000001','00014603-0000-0000-0000-000000000001','00014608-0000-0000-0000-000000000001',1,
 '00014606-0000-0000-0000-000000000001','Product',2,5);

INSERT INTO operaciones.nodos(id,tenant_id,empresa_id,creado_por)
 VALUES('00014604-0000-0000-0000-000000000001','00014602-0000-0000-0000-000000000001','00014603-0000-0000-0000-000000000001','00014601-0000-0000-0000-000000000001');
INSERT INTO catalogo.reservas_inventario(id,tenant_id,empresa_id,nodo_id,referencia_externa,idempotency_key,creado_por)
 VALUES('00014609-0000-0000-0000-000000000001','00014602-0000-0000-0000-000000000001','00014603-0000-0000-0000-000000000001','00014604-0000-0000-0000-000000000001',
 '00014608-0000-0000-0000-000000000001','sales-046-order-key','00014601-0000-0000-0000-000000000001');
UPDATE operaciones.pedidos SET reserva_inventario_ref='00014609-0000-0000-0000-000000000001'
 WHERE id='00014608-0000-0000-0000-000000000001';
INSERT INTO administracion.perfiles_tercero(tenant_id,empresa_id,tercero_id,rol)
 VALUES('00014602-0000-0000-0000-000000000001','00014603-0000-0000-0000-000000000001','00014605-0000-0000-0000-000000000001','cliente');
INSERT INTO operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,estado_nuevo,motivo,actor_id,correlation_id)
 VALUES('00014602-0000-0000-0000-000000000001','00014603-0000-0000-0000-000000000001','00014608-0000-0000-0000-000000000001',
 'PENDING','STOREFRONT_CHECKOUT','00014601-0000-0000-0000-000000000001','00014607-0000-0000-0000-000000000001');
SET LOCAL ROLE mastererp_app;
DO $$
DECLARE result jsonb; replay jsonb; caught boolean; sale uuid;
 company uuid:='00014603-0000-0000-0000-000000000001'; pedido uuid:='00014608-0000-0000-0000-000000000001';
BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 IF has_table_privilege(current_user,'administracion.ventas_origen','INSERT,UPDATE,DELETE')
 OR has_table_privilege(current_user,'administracion.documentos','INSERT,UPDATE,DELETE')
 THEN RAISE EXCEPTION 'Direct sale DML leaked'; END IF;
 PERFORM set_config('app.current_operation','administracion.documento.venta.crear',true);
 result:=administracion.venta_desde_pedido(company,pedido,1,'qa-sales-046-create','2026-11-06');
 sale:=(result->>'id')::uuid;
 IF result->>'estado'<>'ACTIVE' OR NOT EXISTS(SELECT 1 FROM administracion.ventas WHERE id=sale AND total=10 AND cerrado)
 OR operaciones.pedidos_leer(company,pedido)->>'status'<>'CONFIRMED'
 THEN RAISE EXCEPTION 'Atomic confirmation/sale mismatch'; END IF;
 replay:=administracion.venta_desde_pedido(company,pedido,1,'qa-sales-046-create','2026-11-06');
 IF replay IS DISTINCT FROM result THEN RAISE EXCEPTION 'Idempotency replay mismatch'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.venta_desde_pedido(company,pedido,1,'qa-sales-046-create','2026-11-07');
 EXCEPTION WHEN unique_violation THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Changed payload accepted'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.venta_desde_pedido(company,pedido,2,'qa-sales-046-other-key','2026-11-06');
 EXCEPTION WHEN unique_violation THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Second sale accepted'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.venta_desde_pedido(company,pedido,1,'qa-sales-046-stale','2026-11-06');
 EXCEPTION WHEN serialization_failure THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Stale order accepted'; END IF;
 PERFORM set_config('app.current_operation','administracion.venta.anular',true);
 caught:=false;
 BEGIN PERFORM administracion.venta_anular(company,pedido,1,'QA');
 EXCEPTION WHEN check_violation THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Sale cancelled while order active'; END IF;
 PERFORM set_config('app.current_user_id','',true);
 caught:=false;
 BEGIN PERFORM administracion.venta_anular(company,pedido,1,'QA');
 EXCEPTION WHEN insufficient_privilege THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Missing actor accepted'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.ventas_origen) THEN RAISE EXCEPTION 'RLS leaked missing actor'; END IF;
 PERFORM set_config('app.current_user_id','00014601-0000-0000-0000-000000000001',true);
 SET CONSTRAINTS ALL IMMEDIATE;
END $$;
RESET ROLE;
UPDATE plataforma.user_tenants SET permissions_override='{"administration.sales.write":false}'
 WHERE tenant_id='00014602-0000-0000-0000-000000000001' AND user_id='00014601-0000-0000-0000-000000000001';
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 BEGIN
  PERFORM set_config('app.current_operation','administracion.documento.venta.crear',true);
  PERFORM administracion.venta_desde_pedido('00014603-0000-0000-0000-000000000001','00014608-0000-0000-0000-000000000001',1,'qa-sales-046-create','2026-11-06');
  RAISE EXCEPTION 'Revoked permission accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
UPDATE plataforma.user_tenants SET permissions_override='{}'
 WHERE tenant_id='00014602-0000-0000-0000-000000000001' AND user_id='00014601-0000-0000-0000-000000000001';
-- Inactive identity and disabled module must deny even an idempotent replay.
RESET ROLE;
UPDATE plataforma.users SET status='inactive' WHERE id='00014601-0000-0000-0000-000000000001';
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 PERFORM set_config('app.current_operation','administracion.documento.venta.crear',true);
 BEGIN
  PERFORM administracion.venta_desde_pedido('00014603-0000-0000-0000-000000000001','00014608-0000-0000-0000-000000000001',1,'qa-sales-046-create','2026-11-06');
  RAISE EXCEPTION 'Inactive user accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
UPDATE plataforma.users SET status='active' WHERE id='00014601-0000-0000-0000-000000000001';
UPDATE plataforma.tenant_modules SET status='inactive' WHERE tenant_id='00014602-0000-0000-0000-000000000001'
 AND module_id IN(SELECT id FROM plataforma.modules WHERE code='erp.finance');
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 BEGIN
  PERFORM administracion.venta_desde_pedido('00014603-0000-0000-0000-000000000001','00014608-0000-0000-0000-000000000001',1,'qa-sales-046-create','2026-11-06');
  RAISE EXCEPTION 'Disabled finance module accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN
  PERFORM administracion.venta_desde_pedido('00014603-0000-0000-0000-000000000099','00014608-0000-0000-0000-000000000001',1,'qa-sales-046-foreign','2026-11-06');
  RAISE EXCEPTION 'Foreign company accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
UPDATE plataforma.tenant_modules SET status='active' WHERE tenant_id='00014602-0000-0000-0000-000000000001'
 AND module_id IN(SELECT id FROM plataforma.modules WHERE code='erp.finance');
-- Precision failure must roll back both confirmation and sale, including its key.
-- Foreign/missing tenant context must deny even a previously cached response.
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 PERFORM set_config('app.current_tenant_id','',true);
 BEGIN
  PERFORM administracion.venta_desde_pedido('00014603-0000-0000-0000-000000000001','00014608-0000-0000-0000-000000000001',1,'qa-sales-046-create','2026-11-06');
  RAISE EXCEPTION 'Missing tenant accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 IF EXISTS(SELECT 1 FROM administracion.ventas_origen) THEN RAISE EXCEPTION 'RLS tenant leak'; END IF;
 PERFORM set_config('app.current_tenant_id','00014602-0000-0000-0000-000000000001',true);
END $$;
RESET ROLE;
SET CONSTRAINTS ALL DEFERRED;
INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,request_tenant_id,request_fingerprint)
 VALUES('qa-sales-046-invalid-order','00014601-0000-0000-0000-000000000001','operations.orders.create','00014602-0000-0000-0000-000000000001',repeat('b',64));
INSERT INTO operaciones.pedidos(id,tenant_id,empresa_id,sucursal_id,cliente_id,numero,estado,moneda,subtotal,
 cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,reserva_inventario_ref,idempotency_key)
 SELECT '00014608-0000-0000-0000-000000000002',tenant_id,empresa_id,sucursal_id,cliente_id,'QA-046-BAD','PENDING',moneda,10.002,
 cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,'qa-reservation-invalid','qa-sales-046-invalid-order'
 FROM operaciones.pedidos WHERE id='00014608-0000-0000-0000-000000000001';
INSERT INTO operaciones.pedido_lineas(tenant_id,empresa_id,pedido_id,posicion,producto_id,producto_nombre,cantidad,precio_unitario)
 SELECT tenant_id,empresa_id,'00014608-0000-0000-0000-000000000002',1,producto_id,producto_nombre,2,5.001
 FROM operaciones.pedido_lineas WHERE pedido_id='00014608-0000-0000-0000-000000000001';
INSERT INTO operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,estado_nuevo,motivo,actor_id,correlation_id)
 SELECT tenant_id,empresa_id,'00014608-0000-0000-0000-000000000002','PENDING','STOREFRONT_CHECKOUT',actor_id,correlation_id
 FROM operaciones.pedido_eventos WHERE pedido_id='00014608-0000-0000-0000-000000000001' AND motivo='STOREFRONT_CHECKOUT';
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE caught boolean:=false; BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 PERFORM set_config('app.current_operation','administracion.documento.venta.crear',true);
 BEGIN
  PERFORM administracion.venta_desde_pedido('00014603-0000-0000-0000-000000000001','00014608-0000-0000-0000-000000000002',1,'qa-sales-046-invalid','2026-11-06');
  SET CONSTRAINTS ALL IMMEDIATE;
 EXCEPTION WHEN check_violation THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Invalid currency precision accepted'; END IF;
 IF operaciones.pedidos_leer('00014603-0000-0000-0000-000000000001','00014608-0000-0000-0000-000000000002')->>'status'<>'PENDING'
 OR EXISTS(SELECT 1 FROM administracion.ventas_origen WHERE pedido_id='00014608-0000-0000-0000-000000000002')
 OR EXISTS(SELECT 1 FROM plataforma.idempotency_keys WHERE idempotency_key='qa-sales-046-invalid')
 THEN RAISE EXCEPTION 'Partial effects after failed command'; END IF;
 SET CONSTRAINTS ALL IMMEDIATE;
END $$;
RESET ROLE;
-- This is fixture preparation, not evidence that the Operations API releases reservations.
UPDATE operaciones.pedidos SET estado='CANCELLED',version=version+1
 WHERE id='00014608-0000-0000-0000-000000000001';
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 PERFORM set_config('app.current_operation','administracion.venta.anular',true);
 BEGIN
  PERFORM administracion.venta_anular('00014603-0000-0000-0000-000000000001','00014608-0000-0000-0000-000000000001',1,'QA');
  RAISE EXCEPTION 'Cancellation with active inventory reservation accepted';
 EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
RESET ROLE;
UPDATE catalogo.reservas_inventario SET estado='RELEASED'
 WHERE id='00014609-0000-0000-0000-000000000001';
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE result jsonb; BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 PERFORM set_config('app.current_operation','administracion.venta.anular',true);
 result:=administracion.venta_anular('00014603-0000-0000-0000-000000000001','00014608-0000-0000-0000-000000000001',1,'QA sales 046 cancellation');
 IF result->>'estado'<>'CANCELLED' OR (result->>'version')::int<>2
 OR NOT EXISTS(SELECT 1 FROM administracion.ventas WHERE id=(result->>'id')::uuid AND total=10 AND cerrado)
 THEN RAISE EXCEPTION 'Cancellation must preserve commercial history'; END IF;
 SET CONSTRAINTS ALL IMMEDIATE;
END $$;
ROLLBACK;
