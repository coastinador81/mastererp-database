BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-storefront-store-pay-owner','QA Storefront Payment Owner');
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='qa-storefront-store-pay-owner' AND p.code='digital_sales.ecommerce.write';
INSERT INTO plataforma.users(id,email,display_name) VALUES
 ('00005000-0000-0000-0000-000000000001','storefront-store-pay-owner@example.invalid','Storefront Payment Owner');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES
 ('00005000-0000-0000-0000-000000000002','qa-storefront-store-payments','qa-storefront-store-payments','QA Storefront Payments','active');
SELECT set_config('app.current_user_id','00005000-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','00005000-0000-0000-0000-000000000002',true),
 set_config('app.correlation_id','00005000-0000-0000-0000-000000000007',true);
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00005000-0000-0000-0000-000000000002','00005000-0000-0000-0000-000000000001',id,'active'
 FROM plataforma.roles WHERE code='qa-storefront-store-pay-owner';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00005000-0000-0000-0000-000000000002',id,'active' FROM plataforma.modules
 WHERE code='digital_sales.ecommerce';
INSERT INTO catalogo.monedas(codigo,nombre,decimales) VALUES('QZX','QA 50',2);
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00005000-0000-0000-0000-000000000003','00005000-0000-0000-0000-000000000002','QA Storefront Payments','VE','QZX','UTC');
INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code,status)
 VALUES('00005000-0000-0000-0000-000000000004','00005000-0000-0000-0000-000000000002','00005000-0000-0000-0000-000000000003','QA50','QA Node','warehouse','VE','active');
INSERT INTO operaciones.nodos(tenant_id,empresa_id,id,creado_por,estado,acepta_pedidos,tarifa_entrega)
 VALUES('00005000-0000-0000-0000-000000000002','00005000-0000-0000-0000-000000000003','00005000-0000-0000-0000-000000000004','00005000-0000-0000-0000-000000000001','ACTIVE',true,2);
INSERT INTO catalogo.terceros(id,tenant_id,codigo,nombre) VALUES
 ('00005000-0000-0000-0000-000000000005','00005000-0000-0000-0000-000000000002','C50','Cliente 50');
INSERT INTO catalogo.roles_tercero VALUES('00005000-0000-0000-0000-000000000002','00005000-0000-0000-0000-000000000005','cliente');
INSERT INTO administracion.perfiles_tercero(tenant_id,empresa_id,tercero_id,rol,creado_por)
 VALUES('00005000-0000-0000-0000-000000000002','00005000-0000-0000-0000-000000000003','00005000-0000-0000-0000-000000000005','cliente','00005000-0000-0000-0000-000000000001');
INSERT INTO ventas_digitales.tiendas(id,tenant_id,empresa_id,nodo_id,dominio,nombre,estado,creado_por,configuracion)
 VALUES('00005000-0000-0000-0000-000000000006','00005000-0000-0000-0000-000000000002','00005000-0000-0000-0000-000000000003','00005000-0000-0000-0000-000000000004','qa50.example.invalid','QA Store','ACTIVE','00005000-0000-0000-0000-000000000001',
 '{"payments":{"punto-venta-entrega":true,"punto-venta-retiro":true},"paymentDetails":{"customMethods":[
  {"id":"zelle","name":"Zelle","instructions":"Envía a pagos@example.invalid","enabled":true},
  {"id":"binance","name":"Binance Pay","instructions":"ID 123456","enabled":false}]}}');
INSERT INTO catalogo.productos(id,tenant_id,codigo,nombre,precio,estado)
 VALUES('00005000-0000-0000-0000-000000000008','00005000-0000-0000-0000-000000000002','P50','Producto 50',5,'ACTIVE');
INSERT INTO catalogo.inventarios(tenant_id,empresa_id,nodo_id,producto_id,existencia,actualizado_por)
 VALUES('00005000-0000-0000-0000-000000000002','00005000-0000-0000-0000-000000000003',
  '00005000-0000-0000-0000-000000000004','00005000-0000-0000-0000-000000000008',10,
  '00005000-0000-0000-0000-000000000001');

SELECT set_config('app.current_operation','digital_sales.storefront.invitation.create',true);
SET LOCAL ROLE mastererp_app;
DO $$
DECLARE raw_token text:='0f1e2d3c4b5a69780f1e2d3c4b5a6978';
BEGIN
 PERFORM ventas_digitales.cliente_invitacion_crear(
  '00005000-0000-0000-0000-000000000003','00005000-0000-0000-0000-000000000006',
  '00005000-0000-0000-0000-000000000005',encode(digest(convert_to(raw_token,'UTF8'),'sha256'),'hex'),
  transaction_timestamp()+interval '1 day');
 PERFORM set_config('app.current_operation','digital_sales.storefront.identity.claim',true);
 PERFORM ventas_digitales.cliente_identidad_reclamar('https://issuer.example.invalid','customer-sub-50',
  'customer50@example.invalid','Customer 50',raw_token);
END $$;
RESET ROLE;
CREATE FUNCTION pg_temp.qa50_checkout(payment jsonb,idempotency text) RETURNS jsonb LANGUAGE sql AS $f$
 SELECT ventas_digitales.checkout_crear('https://issuer.example.invalid','customer-sub-50','qa50.example.invalid',
  '[{"product_id":"00005000-0000-0000-0000-000000000008","quantity":1}]','{"address":"QA address"}',
  'realtime',payment,idempotency) $f$;
SET LOCAL ROLE mastererp_app;
DO $$
DECLARE pos jsonb;custom jsonb;
BEGIN
 PERFORM set_config('app.current_operation','digital_sales.storefront.checkout',true);
 pos:=pg_temp.qa50_checkout('{"method":"pos"}','qa50-pos');
 custom:=pg_temp.qa50_checkout('{"method":"custom","methodId":"zelle","reference":"778899"}','qa50-custom');
 IF pos->>'id' IS NULL OR custom->>'id' IS NULL THEN RAISE EXCEPTION 'Store payment checkout failed';END IF;
 BEGIN
  PERFORM pg_temp.qa50_checkout('{"method":"custom","methodId":"binance","reference":"778899"}','qa50-disabled');
  RAISE EXCEPTION 'Disabled custom method accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL;
 END;
 BEGIN
  PERFORM pg_temp.qa50_checkout('{"method":"custom","methodId":"unknown","reference":"778899"}','qa50-unknown');
  RAISE EXCEPTION 'Unknown custom method accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL;
 END;
 BEGIN
  PERFORM pg_temp.qa50_checkout('{"method":"custom","methodId":"zelle"}','qa50-noref');
  RAISE EXCEPTION 'Custom method accepted without reference';
 EXCEPTION WHEN invalid_parameter_value THEN NULL;
 END;
END $$;
RESET ROLE;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM operaciones.pedidos WHERE idempotency_key='qa50-pos'
  AND pago_snapshot='{"method":"pos","status":"PENDING_COLLECTION","moment":"delivery"}')
 OR NOT EXISTS(SELECT 1 FROM operaciones.pedidos WHERE idempotency_key='qa50-custom'
  AND pago_snapshot @> '{"method":"custom","status":"PENDING_VERIFICATION","methodId":"zelle","name":"Zelle","reference":"778899"}')
 OR (SELECT count(*) FROM operaciones.pedidos WHERE cliente_id='00005000-0000-0000-0000-000000000005')<>2 THEN
  RAISE EXCEPTION 'Store payment snapshots mismatch';END IF;
 UPDATE ventas_digitales.tiendas SET configuracion='{"payments":{"punto-venta-entrega":false}}'
  WHERE id='00005000-0000-0000-0000-000000000006';
END $$;
SET LOCAL ROLE mastererp_app;
DO $$ BEGIN
 PERFORM set_config('app.current_operation','digital_sales.storefront.checkout',true);
 BEGIN
  PERFORM pg_temp.qa50_checkout('{"method":"pos"}','qa50-pos-off');
  RAISE EXCEPTION 'Disabled Punto de venta accepted';
 EXCEPTION WHEN invalid_parameter_value THEN NULL;
 END;
END $$;
RESET ROLE;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
