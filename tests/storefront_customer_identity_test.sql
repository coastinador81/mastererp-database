BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-storefront-owner','QA Storefront Owner');
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='qa-storefront-owner' AND p.code='digital_sales.ecommerce.write';
INSERT INTO plataforma.users(id,email,display_name) VALUES
 ('00003900-0000-0000-0000-000000000001','storefront-owner@example.invalid','Storefront Owner');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES
 ('00003900-0000-0000-0000-000000000002','qa-storefront-identity','qa-storefront-identity','QA Storefront Identity','active');
SELECT set_config('app.current_user_id','00003900-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','00003900-0000-0000-0000-000000000002',true),
 set_config('app.correlation_id','00003900-0000-0000-0000-000000000007',true);
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00003900-0000-0000-0000-000000000002','00003900-0000-0000-0000-000000000001',id,'active'
 FROM plataforma.roles WHERE code='qa-storefront-owner';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00003900-0000-0000-0000-000000000002',id,'active' FROM plataforma.modules
 WHERE code='digital_sales.ecommerce';
INSERT INTO catalogo.monedas(codigo,nombre,decimales) VALUES('QZZ','QA 39',2);
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00003900-0000-0000-0000-000000000003','00003900-0000-0000-0000-000000000002','QA Storefront','VE','QZZ','UTC');
INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code,status)
 VALUES('00003900-0000-0000-0000-000000000004','00003900-0000-0000-0000-000000000002','00003900-0000-0000-0000-000000000003','QA39','QA Node','warehouse','VE','active');
INSERT INTO operaciones.nodos(tenant_id,empresa_id,id,creado_por,estado,acepta_pedidos,tarifa_entrega)
 VALUES('00003900-0000-0000-0000-000000000002','00003900-0000-0000-0000-000000000003','00003900-0000-0000-0000-000000000004','00003900-0000-0000-0000-000000000001','ACTIVE',true,2);
INSERT INTO catalogo.terceros(id,tenant_id,codigo,nombre) VALUES
 ('00003900-0000-0000-0000-000000000005','00003900-0000-0000-0000-000000000002','C39','Cliente 39');
INSERT INTO catalogo.roles_tercero VALUES('00003900-0000-0000-0000-000000000002','00003900-0000-0000-0000-000000000005','cliente');
INSERT INTO administracion.perfiles_tercero(tenant_id,empresa_id,tercero_id,rol,creado_por)
 VALUES('00003900-0000-0000-0000-000000000002','00003900-0000-0000-0000-000000000003','00003900-0000-0000-0000-000000000005','cliente','00003900-0000-0000-0000-000000000001');
INSERT INTO ventas_digitales.tiendas(id,tenant_id,empresa_id,nodo_id,dominio,nombre,estado,creado_por)
 VALUES('00003900-0000-0000-0000-000000000006','00003900-0000-0000-0000-000000000002','00003900-0000-0000-0000-000000000003','00003900-0000-0000-0000-000000000004','qa39.example.invalid','QA Store','ACTIVE','00003900-0000-0000-0000-000000000001');
INSERT INTO catalogo.productos(id,tenant_id,codigo,nombre,precio,estado)
 VALUES('00003900-0000-0000-0000-000000000008','00003900-0000-0000-0000-000000000002','P39','Producto 39',5,'ACTIVE');
INSERT INTO catalogo.inventarios(tenant_id,empresa_id,nodo_id,producto_id,existencia,actualizado_por)
 VALUES('00003900-0000-0000-0000-000000000002','00003900-0000-0000-0000-000000000003',
  '00003900-0000-0000-0000-000000000004','00003900-0000-0000-0000-000000000008',3,
  '00003900-0000-0000-0000-000000000001');

SELECT set_config('app.current_user_id','00003900-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','00003900-0000-0000-0000-000000000002',true),
 set_config('app.correlation_id','00003900-0000-0000-0000-000000000007',true),
 set_config('app.current_operation','digital_sales.storefront.invitation.create',true);
SET LOCAL ROLE mastererp_app;
DO $$
DECLARE invitation jsonb;claimed jsonb;replayed jsonb;raw_token text:='0123456789abcdef0123456789abcdef';
BEGIN
 invitation:=ventas_digitales.cliente_invitacion_crear(
  '00003900-0000-0000-0000-000000000003','00003900-0000-0000-0000-000000000006',
  '00003900-0000-0000-0000-000000000005',encode(digest(convert_to(raw_token,'UTF8'),'sha256'),'hex'),
  transaction_timestamp()+interval '1 day');
 IF invitation->>'invitation_id' IS NULL THEN RAISE EXCEPTION 'Invitation missing';END IF;
 PERFORM set_config('app.current_operation','digital_sales.storefront.identity.claim',true);
 claimed:=ventas_digitales.cliente_identidad_reclamar('https://issuer.example.invalid','customer-sub-39',
  'customer39@example.invalid','Customer 39',raw_token);
 IF claimed->>'customer_id'<>'00003900-0000-0000-0000-000000000005' OR (claimed->>'replayed')::boolean THEN
  RAISE EXCEPTION 'Claim mismatch';END IF;
 replayed:=ventas_digitales.cliente_identidad_reclamar('https://issuer.example.invalid','customer-sub-39',
  'customer39@example.invalid','Customer 39',raw_token);
 IF (replayed->>'replayed')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'Claim replay mismatch';END IF;
END $$;
DO $$
DECLARE created jsonb;replayed jsonb;
BEGIN
 PERFORM set_config('app.current_operation','digital_sales.storefront.checkout',true);
 created:=ventas_digitales.checkout_crear('https://issuer.example.invalid','customer-sub-39','qa39.example.invalid',
  '[{"product_id":"00003900-0000-0000-0000-000000000008","quantity":2}]','{"address":"QA address"}',
  'realtime','cash','qa-storefront-checkout-39');
 replayed:=ventas_digitales.checkout_crear('https://issuer.example.invalid','customer-sub-39','qa39.example.invalid',
  '[{"product_id":"00003900-0000-0000-0000-000000000008","quantity":2}]','{"address":"QA address"}',
  'realtime','cash','qa-storefront-checkout-39');
 IF created->>'id' IS NULL OR created<>replayed OR created->>'total'<>'12' THEN
  RAISE EXCEPTION 'Checkout response mismatch';END IF;
END $$;
RESET ROLE;
DO $$
DECLARE raw_token text:='0123456789abcdef0123456789abcdef';
BEGIN
 IF (SELECT reservado FROM catalogo.inventarios WHERE producto_id='00003900-0000-0000-0000-000000000008')<>2
 OR (SELECT count(*) FROM operaciones.pedidos WHERE cliente_id='00003900-0000-0000-0000-000000000005')<>1 THEN
  RAISE EXCEPTION 'Checkout was not atomic or idempotent';END IF;
 IF EXISTS(SELECT 1 FROM plataforma.user_tenants WHERE user_id=(SELECT user_id FROM plataforma.external_identities
  WHERE issuer='https://issuer.example.invalid' AND subject='customer-sub-39')) THEN
  RAISE EXCEPTION 'Storefront customer received tenant membership';END IF;
 IF EXISTS(SELECT 1 FROM ventas_digitales.cliente_invitaciones WHERE token_sha256=raw_token) THEN
  RAISE EXCEPTION 'Raw invitation token stored';END IF;
 IF has_table_privilege('mastererp_app','ventas_digitales.cliente_invitaciones','SELECT,INSERT,UPDATE,DELETE')
 OR has_table_privilege('mastererp_app','ventas_digitales.cliente_identidades','SELECT,INSERT,UPDATE,DELETE') THEN
  RAISE EXCEPTION 'Direct Storefront identity DML leaked';END IF;
END $$;
ROLLBACK;
