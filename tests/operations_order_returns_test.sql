BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-order-returns','Order returns fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='qa-order-returns' AND p.code IN (
 'operations.returns.read','operations.returns.write','operations.returns.authorize',
 'catalog.inventory.returns.receive','catalog.inventory.read','administration.returns.settle');
INSERT INTO plataforma.users(id,email,display_name)
 VALUES('00016301-0000-0000-0000-000000000001','returns@example.invalid','Returns operator');
INSERT INTO plataforma.tenants(id,code,slug,name,status)
 VALUES('00016302-0000-0000-0000-000000000001','qa-returns','qa-returns','Returns','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00016302-0000-0000-0000-000000000001','00016301-0000-0000-0000-000000000001',id,'active'
 FROM plataforma.roles WHERE code='qa-order-returns';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00016302-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules
 WHERE code IN ('erp.operations','erp.catalog','erp.finance');
INSERT INTO catalogo.monedas(codigo,nombre,decimales) VALUES('USD','US dollar',2) ON CONFLICT DO NOTHING;
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00016303-0000-0000-0000-000000000001','00016302-0000-0000-0000-000000000001','Returns','US','USD','UTC');
INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code,status)
 VALUES('00016304-0000-0000-0000-000000000001','00016302-0000-0000-0000-000000000001',
 '00016303-0000-0000-0000-000000000001','MAIN','Main','warehouse','US','active');
INSERT INTO operaciones.nodos(id,tenant_id,empresa_id,estado,configuracion,creado_por)
 VALUES('00016304-0000-0000-0000-000000000001','00016302-0000-0000-0000-000000000001',
 '00016303-0000-0000-0000-000000000001','ACTIVE','{}','00016301-0000-0000-0000-000000000001');
INSERT INTO catalogo.terceros(id,tenant_id,codigo,nombre)
 VALUES('00016306-0000-0000-0000-000000000001','00016302-0000-0000-0000-000000000001','CUSTOMER','Customer');
INSERT INTO catalogo.productos(id,tenant_id,codigo,nombre)
 VALUES('00016307-0000-0000-0000-000000000001','00016302-0000-0000-0000-000000000001','PRODUCT','Product');
INSERT INTO catalogo.inventarios(tenant_id,empresa_id,nodo_id,producto_id,existencia,actualizado_por)
 VALUES('00016302-0000-0000-0000-000000000001','00016303-0000-0000-0000-000000000001',
 '00016304-0000-0000-0000-000000000001','00016307-0000-0000-0000-000000000001',5,
 '00016301-0000-0000-0000-000000000001');
INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,request_tenant_id,request_fingerprint)
 VALUES('returns-order-key','00016301-0000-0000-0000-000000000001','operations.orders.create',
 '00016302-0000-0000-0000-000000000001',repeat('a',64));
INSERT INTO operaciones.pedidos(id,tenant_id,empresa_id,sucursal_id,cliente_id,numero,estado,moneda,subtotal,
 cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,reserva_inventario_ref,idempotency_key,creado_por)
 VALUES('00016308-0000-0000-0000-000000000001','00016302-0000-0000-0000-000000000001',
 '00016303-0000-0000-0000-000000000001','00016304-0000-0000-0000-000000000001',
 '00016306-0000-0000-0000-000000000001','ORDER-RETURN','DELIVERED','USD',20,
 '{}','{}','{}','slot','realtime','reservation','returns-order-key','00016301-0000-0000-0000-000000000001');
INSERT INTO operaciones.pedido_lineas(id,tenant_id,empresa_id,pedido_id,posicion,producto_id,producto_nombre,cantidad,precio_unitario)
 VALUES('00016309-0000-0000-0000-000000000001','00016302-0000-0000-0000-000000000001',
 '00016303-0000-0000-0000-000000000001','00016308-0000-0000-0000-000000000001',1,
 '00016307-0000-0000-0000-000000000001','Product',2,10);
SELECT set_config('app.current_user_id','00016301-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','00016302-0000-0000-0000-000000000001',true),
 set_config('app.current_company_id','00016303-0000-0000-0000-000000000001',true),
 set_config('app.correlation_id','00016310-0000-0000-0000-000000000001',true),
 set_config('app.current_operation','operations.returns.request',true);
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE result jsonb; return_id uuid; return_item uuid; BEGIN
 result:=operaciones.devolucion_solicitar('00016303-0000-0000-0000-000000000001',
  '00016308-0000-0000-0000-000000000001',
  '[{"order_item_id":"00016309-0000-0000-0000-000000000001","quantity":1}]','Producto defectuoso','return-request-key');
 IF result->>'status'<>'REQUESTED' OR result->'items'->0->>'requested_quantity'<>'1' THEN
  RAISE EXCEPTION 'Return request mismatch'; END IF;
 return_id:=(result->>'id')::uuid; return_item:=(result->'items'->0->>'id')::uuid;
 PERFORM set_config('app.current_operation','operations.returns.authorize',true);
 result:=operaciones.devolucion_decidir('00016303-0000-0000-0000-000000000001',return_id,1,'AUTHORIZED','Devolución aprobada');
 IF result->>'status'<>'AUTHORIZED' OR result->'items'->0->>'authorized_quantity'<>'1' THEN
  RAISE EXCEPTION 'Return authorization mismatch'; END IF;
 PERFORM set_config('app.current_operation','catalog.inventory.returns.receive',true);
 result:=operaciones.devolucion_recibir('00016303-0000-0000-0000-000000000001',return_id,2,
  '00016304-0000-0000-0000-000000000001',jsonb_build_array(jsonb_build_object('return_item_id',return_item,
  'received_quantity',1,'restocked_quantity',1,'condition','SELLABLE')),'Recepción física verificada');
 IF result->>'status'<>'RECEIVED' OR result->'items'->0->>'restocked_quantity'<>'1' THEN
  RAISE EXCEPTION 'Return receipt mismatch'; END IF;
 IF (catalogo.inventario_leer('00016303-0000-0000-0000-000000000001','00016304-0000-0000-0000-000000000001',
  '00016307-0000-0000-0000-000000000001')->>'stock')::numeric<>6 THEN RAISE EXCEPTION 'Return stock mismatch'; END IF;
 PERFORM set_config('app.current_operation','administration.returns.settle',true);
 BEGIN PERFORM operaciones.devolucion_completar('00016303-0000-0000-0000-000000000001',return_id,3,
  '00016311-0000-0000-0000-000000000001','00016312-0000-0000-0000-000000000001','Referencias inexistentes');
  RAISE EXCEPTION 'Unverified financial references accepted';
 EXCEPTION WHEN check_violation THEN NULL; END;
 result:=operaciones.devoluciones_leer('00016303-0000-0000-0000-000000000001','00016308-0000-0000-0000-000000000001',return_id);
 IF result->>'status'<>'RECEIVED' OR jsonb_array_length(result->'history')<>3
 THEN RAISE EXCEPTION 'Unverified settlement changed return'; END IF;
 IF has_table_privilege('mastererp_app','operaciones.devoluciones_pedido','INSERT,UPDATE,DELETE')
 THEN RAISE EXCEPTION 'Direct return DML leaked'; END IF;
END $$;
ROLLBACK;
