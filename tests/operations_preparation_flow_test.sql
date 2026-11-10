BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-preparation-flow','Preparation flow fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='qa-preparation-flow' AND p.code IN('operations.orders.read','operations.orders.write',
  'operations.preparation.read','operations.preparation.write');
INSERT INTO plataforma.users(id,email,display_name) VALUES('00005101-0000-0000-0000-000000000001','qa-preparation-flow@example.invalid','Preparation flow');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00005102-0000-0000-0000-000000000001','qa-prep-flow','qa-prep-flow','Preparation flow','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00005102-0000-0000-0000-000000000001','00005101-0000-0000-0000-000000000001',id,'active' FROM plataforma.roles WHERE code='qa-preparation-flow';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00005102-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code='erp.operations';
INSERT INTO catalogo.monedas(codigo,nombre,decimales) VALUES('USD','US dollar',2) ON CONFLICT DO NOTHING;
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00005103-0000-0000-0000-000000000001','00005102-0000-0000-0000-000000000001','Preparation flow','US','USD','UTC');
INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code,status)
 VALUES('00005104-0000-0000-0000-000000000001','00005102-0000-0000-0000-000000000001','00005103-0000-0000-0000-000000000001','MAIN','Main','warehouse','US','active');
INSERT INTO operaciones.nodos(id,tenant_id,empresa_id,estado,acepta_pedidos,creado_por)
 VALUES('00005104-0000-0000-0000-000000000001','00005102-0000-0000-0000-000000000001','00005103-0000-0000-0000-000000000001','ACTIVE',true,'00005101-0000-0000-0000-000000000001');
INSERT INTO catalogo.terceros(id,tenant_id,codigo,nombre) VALUES('00005105-0000-0000-0000-000000000001','00005102-0000-0000-0000-000000000001','CUSTOMER','Customer');
INSERT INTO catalogo.roles_tercero VALUES('00005102-0000-0000-0000-000000000001','00005105-0000-0000-0000-000000000001','cliente');
INSERT INTO catalogo.productos(id,tenant_id,codigo,nombre) VALUES('00005106-0000-0000-0000-000000000001','00005102-0000-0000-0000-000000000001','PRODUCT','Product');
INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,request_tenant_id,request_fingerprint)
 SELECT key,'00005101-0000-0000-0000-000000000001','operations.orders.create','00005102-0000-0000-0000-000000000001',repeat('c',64)
 FROM unnest(ARRAY['prep-flow-confirmed','prep-flow-orphan']) key;
INSERT INTO operaciones.pedidos(id,tenant_id,empresa_id,sucursal_id,cliente_id,numero,estado,moneda,subtotal,cliente_snapshot,entrega_snapshot,
 pago_snapshot,ventana_entrega_ref,metodo_entrega,reserva_inventario_ref,idempotency_key,creado_por,version)
VALUES
 ('00005108-0000-0000-0000-000000000001','00005102-0000-0000-0000-000000000001','00005103-0000-0000-0000-000000000001','00005104-0000-0000-0000-000000000001',
  '00005105-0000-0000-0000-000000000001','PREP-CONFIRMED','CONFIRMED','USD',10,'{}','{}','{"method":"cash","status":"PENDING_COLLECTION"}',
  'slot','realtime','reservation-a','prep-flow-confirmed','00005101-0000-0000-0000-000000000001',1),
 ('00005108-0000-0000-0000-000000000002','00005102-0000-0000-0000-000000000001','00005103-0000-0000-0000-000000000001','00005104-0000-0000-0000-000000000001',
  '00005105-0000-0000-0000-000000000001','PREP-ORPHAN','PREPARING','USD',10,'{}','{}','{"method":"cash","status":"PENDING_COLLECTION"}',
  'slot','realtime','reservation-b','prep-flow-orphan','00005101-0000-0000-0000-000000000001',3);
INSERT INTO operaciones.pedido_lineas(tenant_id,empresa_id,pedido_id,posicion,producto_id,producto_nombre,cantidad,precio_unitario)
 SELECT '00005102-0000-0000-0000-000000000001','00005103-0000-0000-0000-000000000001',pedido,1,'00005106-0000-0000-0000-000000000001','Product',2,5
 FROM unnest(ARRAY['00005108-0000-0000-0000-000000000001','00005108-0000-0000-0000-000000000002']::uuid[]) pedido;
SELECT set_config('app.current_user_id','00005101-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','00005102-0000-0000-0000-000000000001',true),
 set_config('app.current_company_id','00005103-0000-0000-0000-000000000001',true),
 set_config('app.correlation_id','00005107-0000-0000-0000-000000000001',true),
 set_config('app.current_operation','operations.orders.transition',true);
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE item jsonb; caught boolean;
 company uuid:='00005103-0000-0000-0000-000000000001'; node uuid:='00005104-0000-0000-0000-000000000001';
 confirmed uuid:='00005108-0000-0000-0000-000000000001'; orphan uuid:='00005108-0000-0000-0000-000000000002';
BEGIN
 caught:=false;
 BEGIN PERFORM operaciones.pedido_transicionar(company,confirmed,1,'PREPARING','MANUAL_OPERATION');
 EXCEPTION WHEN check_violation THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Generic transition bypassed preparation'; END IF;
 caught:=false;
 BEGIN PERFORM operaciones.pedido_transicionar(company,orphan,3,'READY','MANUAL_OPERATION');
 EXCEPTION WHEN check_violation THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Generic transition bypassed preparation completion'; END IF;
 PERFORM set_config('app.current_operation','operations.preparation.start',true);
 item:=operaciones.preparacion_iniciar(company,confirmed,node,1);
 IF item->>'status'<>'IN_PROGRESS' OR jsonb_array_length(item->'items')<>1
 OR operaciones.pedidos_leer(company,confirmed)->>'status'<>'PREPARING' THEN RAISE EXCEPTION 'Preparation start mismatch'; END IF;
 item:=operaciones.preparacion_iniciar(company,orphan,node,3);
 IF item->>'status'<>'IN_PROGRESS' OR jsonb_array_length(item->'items')<>1
 OR (operaciones.pedidos_leer(company,orphan)->>'version')::int<>3 THEN RAISE EXCEPTION 'Orphan preparation mismatch'; END IF;
 caught:=false;
 BEGIN PERFORM operaciones.preparacion_iniciar(company,orphan,node,3);
 EXCEPTION WHEN check_violation THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Preparation started twice'; END IF;
 PERFORM set_config('app.current_operation','operations.preparation.read',true);
 IF jsonb_array_length(operaciones.preparacion_leer(company,NULL,'IN_PROGRESS',50))<>2 THEN RAISE EXCEPTION 'Preparation queue mismatch'; END IF;
END $$;
ROLLBACK;
