BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-fulfillment','Fulfillment fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='qa-fulfillment' AND p.code IN(
  'operations.orders.read','operations.orders.write','operations.preparation.read','operations.preparation.write','operations.routes.read','operations.routes.write',
  'catalog.inventory.reserve','digital_sales.ecommerce.read','digital_sales.ecommerce.write');
INSERT INTO plataforma.users(id,email,display_name) VALUES('00008001-0000-0000-0000-000000000001','qa-fulfillment@example.invalid','Fulfillment test');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00008002-0000-0000-0000-000000000001','qa-fulfillment','qa-fulfillment','Fulfillment','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00008002-0000-0000-0000-000000000001','00008001-0000-0000-0000-000000000001',id,'active' FROM plataforma.roles WHERE code='qa-fulfillment';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00008002-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules
 WHERE code IN('erp.operations','erp.catalog','erp.transport','digital_sales.ecommerce');
INSERT INTO catalogo.monedas(codigo,nombre,decimales) VALUES('USD','US dollar',2) ON CONFLICT DO NOTHING;
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00008003-0000-0000-0000-000000000001','00008002-0000-0000-0000-000000000001','Fulfillment','US','USD','UTC');
INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code,status)
 VALUES('00008004-0000-0000-0000-000000000001','00008002-0000-0000-0000-000000000001','00008003-0000-0000-0000-000000000001','MAIN','Main','warehouse','US','active');
INSERT INTO operaciones.nodos(id,tenant_id,empresa_id,estado,acepta_pedidos,creado_por)
 VALUES('00008004-0000-0000-0000-000000000001','00008002-0000-0000-0000-000000000001','00008003-0000-0000-0000-000000000001','ACTIVE',true,'00008001-0000-0000-0000-000000000001');
INSERT INTO catalogo.terceros(id,tenant_id,codigo,nombre) VALUES('00008005-0000-0000-0000-000000000001','00008002-0000-0000-0000-000000000001','CUSTOMER','Customer');
INSERT INTO catalogo.roles_tercero VALUES('00008002-0000-0000-0000-000000000001','00008005-0000-0000-0000-000000000001','cliente');
INSERT INTO catalogo.productos(id,tenant_id,codigo,nombre,precio,estado) VALUES('00008006-0000-0000-0000-000000000001','00008002-0000-0000-0000-000000000001','PRODUCT','Public product',15,'ACTIVE');
INSERT INTO catalogo.inventarios(tenant_id,empresa_id,nodo_id,producto_id,existencia,reservado,actualizado_por)
 VALUES('00008002-0000-0000-0000-000000000001','00008003-0000-0000-0000-000000000001','00008004-0000-0000-0000-000000000001','00008006-0000-0000-0000-000000000001',10,2,'00008001-0000-0000-0000-000000000001');
INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,request_tenant_id,request_fingerprint)
 VALUES('fulfillment-reservation','00008001-0000-0000-0000-000000000001','catalog.inventory.reserve','00008002-0000-0000-0000-000000000001',repeat('b',64)),
 ('fulfillment-order','00008001-0000-0000-0000-000000000001','operations.orders.create','00008002-0000-0000-0000-000000000001',repeat('b',64)),
 ('fulfillment-cancel-reservation','00008001-0000-0000-0000-000000000001','catalog.inventory.reserve','00008002-0000-0000-0000-000000000001',repeat('b',64)),
 ('fulfillment-cancel-order','00008001-0000-0000-0000-000000000001','operations.orders.create','00008002-0000-0000-0000-000000000001',repeat('b',64));
INSERT INTO catalogo.reservas_inventario(id,tenant_id,empresa_id,nodo_id,referencia_externa,idempotency_key,creado_por)
 VALUES('00008007-0000-0000-0000-000000000001','00008002-0000-0000-0000-000000000001','00008003-0000-0000-0000-000000000001','00008004-0000-0000-0000-000000000001','ORDER-READY','fulfillment-reservation','00008001-0000-0000-0000-000000000001');
INSERT INTO catalogo.reservas_inventario(id,tenant_id,empresa_id,nodo_id,referencia_externa,idempotency_key,creado_por)
 VALUES('00008007-0000-0000-0000-000000000002','00008002-0000-0000-0000-000000000001','00008003-0000-0000-0000-000000000001','00008004-0000-0000-0000-000000000001','ORDER-CANCEL','fulfillment-cancel-reservation','00008001-0000-0000-0000-000000000001');
INSERT INTO catalogo.reserva_inventario_lineas VALUES('00008002-0000-0000-0000-000000000001','00008003-0000-0000-0000-000000000001','00008007-0000-0000-0000-000000000001','00008004-0000-0000-0000-000000000001','00008006-0000-0000-0000-000000000001',1);
INSERT INTO catalogo.reserva_inventario_lineas VALUES('00008002-0000-0000-0000-000000000001','00008003-0000-0000-0000-000000000001','00008007-0000-0000-0000-000000000002','00008004-0000-0000-0000-000000000001','00008006-0000-0000-0000-000000000001',1);
INSERT INTO operaciones.pedidos(id,tenant_id,empresa_id,sucursal_id,cliente_id,numero,estado,moneda,subtotal,cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,reserva_inventario_ref,idempotency_key,creado_por,version)
 VALUES('00008008-0000-0000-0000-000000000001','00008002-0000-0000-0000-000000000001','00008003-0000-0000-0000-000000000001','00008004-0000-0000-0000-000000000001','00008005-0000-0000-0000-000000000001','ORDER-READY','CONFIRMED','USD',15,'{}','{}','{}','slot','realtime','00008007-0000-0000-0000-000000000001','fulfillment-order','00008001-0000-0000-0000-000000000001',1);
INSERT INTO operaciones.pedidos(id,tenant_id,empresa_id,sucursal_id,cliente_id,numero,estado,moneda,subtotal,cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,reserva_inventario_ref,idempotency_key,creado_por,version)
 VALUES('00008008-0000-0000-0000-000000000002','00008002-0000-0000-0000-000000000001','00008003-0000-0000-0000-000000000001','00008004-0000-0000-0000-000000000001','00008005-0000-0000-0000-000000000001','ORDER-CANCEL','PENDING','USD',15,'{}','{}','{"method":"cash","status":"PENDING_COLLECTION"}','slot','realtime','00008007-0000-0000-0000-000000000002','fulfillment-cancel-order','00008001-0000-0000-0000-000000000001',1);
INSERT INTO operaciones.pedido_lineas(id,tenant_id,empresa_id,pedido_id,posicion,producto_id,producto_nombre,cantidad,precio_unitario)
 VALUES('00008009-0000-0000-0000-000000000001','00008002-0000-0000-0000-000000000001','00008003-0000-0000-0000-000000000001','00008008-0000-0000-0000-000000000001',1,'00008006-0000-0000-0000-000000000001','Public product',1,15);
INSERT INTO operaciones.pedido_lineas(id,tenant_id,empresa_id,pedido_id,posicion,producto_id,producto_nombre,cantidad,precio_unitario)
 VALUES('00008009-0000-0000-0000-000000000002','00008002-0000-0000-0000-000000000001','00008003-0000-0000-0000-000000000001','00008008-0000-0000-0000-000000000002',1,'00008006-0000-0000-0000-000000000001','Public product',1,15);
INSERT INTO transporte.repartidores(id,tenant_id,codigo,nombre,telefono,estado,disponibilidad,creado_por)
 VALUES('00008010-0000-0000-0000-000000000001','00008002-0000-0000-0000-000000000001','DRIVER','Driver','04140000000','ACTIVE','AVAILABLE','00008001-0000-0000-0000-000000000001');
INSERT INTO transporte.repartidor_nodos VALUES('00008002-0000-0000-0000-000000000001','00008003-0000-0000-0000-000000000001','00008004-0000-0000-0000-000000000001','00008010-0000-0000-0000-000000000001',true,transaction_timestamp());
SELECT set_config('app.current_user_id','00008001-0000-0000-0000-000000000001',true),set_config('app.current_tenant_id','00008002-0000-0000-0000-000000000001',true),set_config('app.current_company_id','00008003-0000-0000-0000-000000000001',true),set_config('app.correlation_id','00008011-0000-0000-0000-000000000001',true),set_config('app.current_operation','operations.preparation.start',true);
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE item jsonb; route jsonb; store jsonb; rid uuid; BEGIN
 PERFORM set_config('app.current_operation','operations.orders.cancel',true);
 item:=operaciones.pedido_cancelar('00008003-0000-0000-0000-000000000001','00008008-0000-0000-0000-000000000002',1,'CUSTOMER_REQUEST',NULL);
 IF item->>'status'<>'CANCELLED' OR item->'inventory'->>'status'<>'RELEASED'
 OR (SELECT reservado FROM catalogo.inventarios WHERE tenant_id='00008002-0000-0000-0000-000000000001' AND empresa_id='00008003-0000-0000-0000-000000000001' AND nodo_id='00008004-0000-0000-0000-000000000001' AND producto_id='00008006-0000-0000-0000-000000000001')<>1
 THEN RAISE EXCEPTION 'Coordinated cancellation mismatch'; END IF;
 PERFORM set_config('app.current_operation','operations.preparation.start',true);
 item:=operaciones.preparacion_iniciar('00008003-0000-0000-0000-000000000001','00008008-0000-0000-0000-000000000001','00008004-0000-0000-0000-000000000001',1);
 PERFORM set_config('app.current_operation','operations.preparation.item.update',true);
 item:=operaciones.preparacion_linea_marcar('00008003-0000-0000-0000-000000000001','00008008-0000-0000-0000-000000000001','00008009-0000-0000-0000-000000000001',1,'DONE',NULL);
 PERFORM set_config('app.current_operation','operations.preparation.complete',true);
 item:=operaciones.preparacion_completar('00008003-0000-0000-0000-000000000001','00008008-0000-0000-0000-000000000001',2);
 IF item->>'status'<>'COMPLETED' OR operaciones.pedidos_leer('00008003-0000-0000-0000-000000000001','00008008-0000-0000-0000-000000000001')->>'status'<>'READY' THEN RAISE EXCEPTION 'Preparation completion mismatch'; END IF;
 PERFORM set_config('app.current_operation','operations.routes.create',true);
 route:=operaciones.ruta_crear('00008003-0000-0000-0000-000000000001','00008004-0000-0000-0000-000000000001',current_date,'slot','["00008008-0000-0000-0000-000000000001"]','fulfillment-route');rid:=(route->>'id')::uuid;
 PERFORM set_config('app.current_operation','operations.routes.assign',true);route:=operaciones.ruta_asignar('00008003-0000-0000-0000-000000000001',rid,1,'00008010-0000-0000-0000-000000000001');
 PERFORM set_config('app.current_operation','operations.routes.transition',true);route:=operaciones.ruta_transicionar('00008003-0000-0000-0000-000000000001',rid,2,'IN_ROUTE');
 PERFORM set_config('app.current_operation','operations.routes.stop.complete',true);route:=operaciones.ruta_parada_finalizar('00008003-0000-0000-0000-000000000001',rid,'00008008-0000-0000-0000-000000000001','DELIVERED','{}');
 PERFORM set_config('app.current_operation','operations.routes.transition',true);route:=operaciones.ruta_transicionar('00008003-0000-0000-0000-000000000001',rid,3,'COMPLETED');
 IF route->>'status'<>'COMPLETED' OR operaciones.pedidos_leer('00008003-0000-0000-0000-000000000001','00008008-0000-0000-0000-000000000001')->>'status'<>'DELIVERED' THEN RAISE EXCEPTION 'Route completion mismatch'; END IF;
 PERFORM set_config('app.current_operation','digital_sales.ecommerce.configure',true);store:=ventas_digitales.tienda_configurar('00008003-0000-0000-0000-000000000001',NULL,'00008004-0000-0000-0000-000000000001','shop.example.test','Test shop',NULL,'{"branding":{"primaryColor":"#123456"}}');
 store:=ventas_digitales.tienda_configurar('00008003-0000-0000-0000-000000000001',(store->>'id')::uuid,NULL,NULL,NULL,1,'{"status":"ACTIVE"}');
 store:=ventas_digitales.catalogo_publico('shop.example.test',20);
 IF jsonb_array_length(store->'products')<>1 OR store->'store'->>'name'<>'Test shop' THEN RAISE EXCEPTION 'Public catalog mismatch'; END IF;
 IF has_table_privilege('mastererp_app','operaciones.rutas','INSERT,UPDATE,DELETE') OR has_table_privilege('mastererp_app','ventas_digitales.tiendas','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Direct fulfillment DML leaked'; END IF;
END $$;
ROLLBACK;
