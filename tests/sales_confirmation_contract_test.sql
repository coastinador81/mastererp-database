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
DELETE FROM plataforma.role_permissions WHERE role_id IN(SELECT id FROM plataforma.roles WHERE code='qa-sales-046-sql') AND permission_code='operations.orders.write';
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE sale jsonb; replay jsonb; caught boolean:=false; BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 IF plataforma.has_current_tenant_permission('operations.orders.write') THEN RAISE EXCEPTION 'Broad operational write must not be needed'; END IF;
 PERFORM set_config('app.current_operation','administracion.documento.venta.crear',true);
 PERFORM set_config('app.sale_confirmation_reason','QA_APPROVED',true);
 PERFORM set_config('app.sale_confirmation_detail','QA contract detail',true);
 sale:=administracion.venta_desde_pedido('00014603-0000-0000-0000-000000000001','00014608-0000-0000-0000-000000000001',1,'qa-sales-047-confirm',NULL);
 replay:=administracion.venta_desde_pedido('00014603-0000-0000-0000-000000000001','00014608-0000-0000-0000-000000000001',1,'qa-sales-047-confirm',NULL);
 IF sale IS DISTINCT FROM replay THEN RAISE EXCEPTION 'Confirmation replay mismatch'; END IF;
 PERFORM set_config('app.sale_confirmation_reason','QA_DIFFERENT',true);
 BEGIN
  PERFORM administracion.venta_desde_pedido('00014603-0000-0000-0000-000000000001','00014608-0000-0000-0000-000000000001',1,'qa-sales-047-confirm',NULL);
 EXCEPTION WHEN unique_violation THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Changed confirmation reason accepted'; END IF;
 SET CONSTRAINTS ALL IMMEDIATE;
END $$;
RESET ROLE;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM operaciones.pedido_eventos WHERE pedido_id='00014608-0000-0000-0000-000000000001'
 AND estado_nuevo='CONFIRMED' AND motivo='QA_APPROVED' AND detalle='QA contract detail')
 THEN RAISE EXCEPTION 'Confirmation reason/detail lost'; END IF;
END $$;

DO $$
DECLARE method text; target uuid; counter integer:=0; caught boolean; result jsonb;
BEGIN
 IF has_function_privilege('mastererp_app','operaciones.pedido_confirmar_para_venta(uuid,uuid,bigint,text,text)','EXECUTE')
 THEN RAISE EXCEPTION 'Private helper exposed'; END IF;
 FOR method IN SELECT unnest(ARRAY['mobile','transfer','unknown']) LOOP
  counter:=counter+1; target:=gen_random_uuid();
  INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,request_tenant_id,request_fingerprint)
   VALUES('qa-sales-047-payment-order-'||counter,'00014601-0000-0000-0000-000000000001','operations.orders.create',
   '00014602-0000-0000-0000-000000000001',repeat('c',64));
  INSERT INTO operaciones.pedidos(id,tenant_id,empresa_id,sucursal_id,cliente_id,numero,estado,moneda,subtotal,
   cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,reserva_inventario_ref,idempotency_key)
   SELECT target,tenant_id,empresa_id,sucursal_id,cliente_id,'QA-047-PAY-'||counter,'PENDING',moneda,subtotal,
   cliente_snapshot,entrega_snapshot,jsonb_build_object('method',method,'status',CASE WHEN method='unknown' THEN 'VALIDATED' ELSE 'PENDING_VERIFICATION' END),
   ventana_entrega_ref,metodo_entrega,reserva_inventario_ref,'qa-sales-047-payment-order-'||counter
   FROM operaciones.pedidos WHERE id='00014608-0000-0000-0000-000000000001';
  INSERT INTO operaciones.pedido_lineas(tenant_id,empresa_id,pedido_id,posicion,producto_id,producto_nombre,cantidad,precio_unitario)
   SELECT tenant_id,empresa_id,target,posicion,producto_id,producto_nombre,cantidad,precio_unitario
   FROM operaciones.pedido_lineas WHERE pedido_id='00014608-0000-0000-0000-000000000001';
  INSERT INTO operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,estado_nuevo,motivo,actor_id,correlation_id)
   VALUES('00014602-0000-0000-0000-000000000001','00014603-0000-0000-0000-000000000001',target,'PENDING','STOREFRONT_CHECKOUT',
   '00014601-0000-0000-0000-000000000001','00014607-0000-0000-0000-000000000001');
  SET LOCAL ROLE mastererp_app;
  IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
  caught:=false;
  BEGIN
   PERFORM administracion.venta_desde_pedido('00014603-0000-0000-0000-000000000001',target,1,'qa-sales-047-pay-'||counter,NULL);
  EXCEPTION WHEN check_violation THEN caught:=true; END;
  IF NOT caught THEN RAISE EXCEPTION 'Pending or unknown payment accepted'; END IF;
  RESET ROLE;
  IF EXISTS(SELECT 1 FROM administracion.ventas_origen WHERE pedido_id=target)
  THEN RAISE EXCEPTION 'Failed payment left partial sale'; END IF;
  IF method<>'unknown' THEN
   UPDATE operaciones.pedidos SET pago_snapshot=jsonb_build_object('method',method,'status','VALIDATED') WHERE id=target;
   SET LOCAL ROLE mastererp_app;
   IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
   result:=administracion.venta_desde_pedido('00014603-0000-0000-0000-000000000001',target,1,'qa-sales-047-pay-'||counter,NULL);
   IF result->>'estado'<>'ACTIVE' THEN RAISE EXCEPTION 'Validated current payment alias rejected'; END IF;
   RESET ROLE;
  END IF;
 END LOOP;
 SET CONSTRAINTS ALL IMMEDIATE;
END $$;

ROLLBACK;
