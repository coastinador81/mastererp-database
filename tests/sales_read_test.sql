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

INSERT INTO plataforma.roles(code,name) VALUES('qa-sales-read-048','Sales read only fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code) SELECT id,'administration.read' FROM plataforma.roles WHERE code='qa-sales-read-048';
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00014802-0000-0000-0000-000000000099','qa-sales-read-foreign','qa-sales-read-foreign','Foreign read fixture','active');
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00014803-0000-0000-0000-000000000099','00014802-0000-0000-0000-000000000099','Foreign read fixture','US','USD','UTC');
DO $$ DECLARE target uuid; n integer; BEGIN
 FOR n IN 1..2 LOOP
  target:=gen_random_uuid();
  INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,request_tenant_id,request_fingerprint)
   VALUES('qa-sales-read-order-'||n,'00014601-0000-0000-0000-000000000001','operations.orders.create','00014602-0000-0000-0000-000000000001',repeat('d',64));
  INSERT INTO operaciones.pedidos(id,tenant_id,empresa_id,sucursal_id,cliente_id,numero,estado,moneda,subtotal,
   cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,reserva_inventario_ref,idempotency_key)
   SELECT target,tenant_id,empresa_id,sucursal_id,cliente_id,'QA048-ORDER-'||n,'PENDING',moneda,subtotal,
   cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,reserva_inventario_ref,'qa-sales-read-order-'||n
   FROM operaciones.pedidos WHERE id='00014608-0000-0000-0000-000000000001';
  INSERT INTO operaciones.pedido_lineas(tenant_id,empresa_id,pedido_id,posicion,producto_id,producto_nombre,cantidad,precio_unitario)
   SELECT tenant_id,empresa_id,target,posicion,producto_id,producto_nombre,cantidad,precio_unitario
   FROM operaciones.pedido_lineas WHERE pedido_id='00014608-0000-0000-0000-000000000001';
  INSERT INTO operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,estado_nuevo,motivo,actor_id,correlation_id)
   VALUES('00014602-0000-0000-0000-000000000001','00014603-0000-0000-0000-000000000001',target,'PENDING','STOREFRONT_CHECKOUT',
   '00014601-0000-0000-0000-000000000001','00014607-0000-0000-0000-000000000001');
 END LOOP;
END $$;
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE id uuid; BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 PERFORM set_config('app.current_operation','administracion.documento.venta.crear',true);
 FOR id IN SELECT (item->>'id')::uuid FROM jsonb_array_elements(operaciones.pedidos_leer('00014603-0000-0000-0000-000000000001')) item LOOP
  PERFORM administracion.venta_desde_pedido('00014603-0000-0000-0000-000000000001',id,1,'qa-sales-read-'||id::text,'2026-11-07');
 END LOOP;
 SET CONSTRAINTS ALL IMMEDIATE;
END $$;
RESET ROLE;
UPDATE catalogo.terceros SET nombre='Changed master name',version=version+1 WHERE id='00014605-0000-0000-0000-000000000001';
UPDATE plataforma.user_tenants SET role_id=(SELECT id FROM plataforma.roles WHERE code='qa-sales-read-048')
 WHERE tenant_id='00014602-0000-0000-0000-000000000001' AND user_id='00014601-0000-0000-0000-000000000001';
SET LOCAL ROLE mastererp_app;
DO $$
DECLARE company uuid:='00014603-0000-0000-0000-000000000001'; page jsonb; next_page jsonb; detail jsonb; item jsonb; caught boolean;
BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 IF plataforma.has_current_tenant_permission('administration.parties.read') OR plataforma.has_current_tenant_permission('operations.orders.write')
 THEN RAISE EXCEPTION 'Reader gained unrelated permission'; END IF;
 IF jsonb_array_length(plataforma.current_frontend_context()->'companies')<>1 THEN RAISE EXCEPTION 'Finance reader lost company context'; END IF;
 page:=administracion.ventas_leer(company,NULL,1);
 next_page:=administracion.ventas_leer(company,NULL,100,(page->0->>'id')::uuid);
 IF jsonb_array_length(page)<>1 OR jsonb_array_length(next_page)<>2 OR EXISTS(
 SELECT 1 FROM jsonb_array_elements(next_page) r WHERE r->>'id'=page->0->>'id') THEN RAISE EXCEPTION 'Sales cursor skipped or duplicated rows'; END IF;
 detail:=administracion.ventas_leer(company,(page->0->>'id')::uuid);
 IF jsonb_typeof(detail->'total')<>'string' OR detail->>'total'<>'10'
 OR detail->'cliente'->>'nombre'<>'Customer' OR jsonb_array_length(detail->'lineas')<>1
 OR detail->'lineas'->0->>'precio_unitario'<>'5' THEN RAISE EXCEPTION 'Sales detail, historical name or money precision mismatch'; END IF;
 IF jsonb_array_length(administracion.ventas_leer(company,NULL,100,NULL,'qa048-order'))<>2
 OR jsonb_array_length(administracion.ventas_leer(company,NULL,100,NULL,'no-matches-048'))<>0 THEN RAISE EXCEPTION 'Server-side search mismatch'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.ventas_leer('00014803-0000-0000-0000-000000000099');EXCEPTION WHEN insufficient_privilege THEN caught:=true;END;
 IF NOT caught THEN RAISE EXCEPTION 'Foreign company read accepted'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.ventas_leer(company,'00014803-0000-0000-0000-000000000099');EXCEPTION WHEN no_data_found THEN caught:=true;END;
 IF NOT caught THEN RAISE EXCEPTION 'Unknown sale exposed'; END IF;
 caught:=false;
 BEGIN PERFORM administracion.ventas_leer(company,NULL,10,'00014803-0000-0000-0000-000000000099');EXCEPTION WHEN invalid_parameter_value THEN caught:=true;END;
 IF NOT caught THEN RAISE EXCEPTION 'Foreign cursor accepted'; END IF;
 PERFORM set_config('app.current_tenant_id','',true);
 caught:=false;
 BEGIN PERFORM administracion.ventas_leer(company);EXCEPTION WHEN insufficient_privilege THEN caught:=true;END;
 IF NOT caught THEN RAISE EXCEPTION 'Missing tenant context accepted'; END IF;
 PERFORM set_config('app.current_tenant_id','00014602-0000-0000-0000-000000000001',true);
 SET CONSTRAINTS ALL IMMEDIATE;
END $$;
RESET ROLE;
UPDATE plataforma.user_tenants SET permissions_override='{"administration.read":false}'
 WHERE tenant_id='00014602-0000-0000-0000-000000000001' AND user_id='00014601-0000-0000-0000-000000000001';
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN
 IF current_user<>'mastererp_app' THEN RAISE EXCEPTION 'Wrong effective role'; END IF;
 BEGIN PERFORM administracion.ventas_leer('00014603-0000-0000-0000-000000000001');RAISE EXCEPTION 'Denied override accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END $$;
ROLLBACK;
