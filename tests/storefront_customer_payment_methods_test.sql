BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-storefront-pay-owner','QA Storefront Payment Owner');
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='qa-storefront-pay-owner' AND p.code='digital_sales.ecommerce.write';
INSERT INTO plataforma.users(id,email,display_name) VALUES
 ('00004900-0000-0000-0000-000000000001','storefront-pay-owner@example.invalid','Storefront Payment Owner');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES
 ('00004900-0000-0000-0000-000000000002','qa-storefront-payments','qa-storefront-payments','QA Storefront Payments','active');
SELECT set_config('app.current_user_id','00004900-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','00004900-0000-0000-0000-000000000002',true),
 set_config('app.correlation_id','00004900-0000-0000-0000-000000000007',true);
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00004900-0000-0000-0000-000000000002','00004900-0000-0000-0000-000000000001',id,'active'
 FROM plataforma.roles WHERE code='qa-storefront-pay-owner';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00004900-0000-0000-0000-000000000002',id,'active' FROM plataforma.modules
 WHERE code='digital_sales.ecommerce';
INSERT INTO catalogo.monedas(codigo,nombre,decimales) VALUES('QZY','QA 49',2);
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00004900-0000-0000-0000-000000000003','00004900-0000-0000-0000-000000000002','QA Storefront Payments','VE','QZY','UTC');
INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code,status)
 VALUES('00004900-0000-0000-0000-000000000004','00004900-0000-0000-0000-000000000002','00004900-0000-0000-0000-000000000003','QA49','QA Node','warehouse','VE','active');
INSERT INTO operaciones.nodos(tenant_id,empresa_id,id,creado_por,estado,acepta_pedidos,tarifa_entrega)
 VALUES('00004900-0000-0000-0000-000000000002','00004900-0000-0000-0000-000000000003','00004900-0000-0000-0000-000000000004','00004900-0000-0000-0000-000000000001','ACTIVE',true,2);
INSERT INTO catalogo.terceros(id,tenant_id,codigo,nombre) VALUES
 ('00004900-0000-0000-0000-000000000005','00004900-0000-0000-0000-000000000002','C49','Cliente 49');
INSERT INTO catalogo.roles_tercero VALUES('00004900-0000-0000-0000-000000000002','00004900-0000-0000-0000-000000000005','cliente');
INSERT INTO administracion.perfiles_tercero(tenant_id,empresa_id,tercero_id,rol,creado_por)
 VALUES('00004900-0000-0000-0000-000000000002','00004900-0000-0000-0000-000000000003','00004900-0000-0000-0000-000000000005','cliente','00004900-0000-0000-0000-000000000001');
INSERT INTO ventas_digitales.tiendas(id,tenant_id,empresa_id,nodo_id,dominio,nombre,estado,creado_por)
 VALUES('00004900-0000-0000-0000-000000000006','00004900-0000-0000-0000-000000000002','00004900-0000-0000-0000-000000000003','00004900-0000-0000-0000-000000000004','qa49.example.invalid','QA Store','ACTIVE','00004900-0000-0000-0000-000000000001');

SELECT set_config('app.current_operation','digital_sales.storefront.invitation.create',true);
SET LOCAL ROLE mastererp_app;
DO $$
DECLARE raw_token text:='fedcba9876543210fedcba9876543210';
BEGIN
 PERFORM ventas_digitales.cliente_invitacion_crear(
  '00004900-0000-0000-0000-000000000003','00004900-0000-0000-0000-000000000006',
  '00004900-0000-0000-0000-000000000005',encode(digest(convert_to(raw_token,'UTF8'),'sha256'),'hex'),
  transaction_timestamp()+interval '1 day');
 PERFORM set_config('app.current_operation','digital_sales.storefront.identity.claim',true);
 PERFORM ventas_digitales.cliente_identidad_reclamar('https://issuer.example.invalid','customer-sub-49',
  'customer49@example.invalid','Customer 49',raw_token);
END $$;
DO $$
DECLARE saved jsonb;
BEGIN
 PERFORM set_config('app.current_operation','digital_sales.storefront.customer.read',true);
 BEGIN
  PERFORM ventas_digitales.cliente_metodo_pago_guardar('https://issuer.example.invalid','customer-sub-49',
   'qa49.example.invalid','mobile','0102','V12345678','04121234567',NULL);
  RAISE EXCEPTION 'Read operation saved a payment method';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 PERFORM set_config('app.current_operation','digital_sales.storefront.checkout',true);
 BEGIN
  PERFORM ventas_digitales.cliente_metodo_pago_guardar('https://issuer.example.invalid','customer-sub-49',
   'qa49.example.invalid','mobile','0102','V12345678',NULL,NULL);
  RAISE EXCEPTION 'Mobile payment saved without phone';
 EXCEPTION WHEN invalid_parameter_value THEN NULL;
 END;
 PERFORM ventas_digitales.cliente_metodo_pago_guardar('https://issuer.example.invalid','customer-sub-49',
  'qa49.example.invalid','mobile','0102','v12345678','04121234567',NULL);
 PERFORM ventas_digitales.cliente_metodo_pago_guardar('https://issuer.example.invalid','customer-sub-49',
  'qa49.example.invalid','mobile','0134','V87654321','04149876543',NULL);
 PERFORM ventas_digitales.cliente_metodo_pago_guardar('https://issuer.example.invalid','customer-sub-49',
  'qa49.example.invalid','transfer','0105','J123456789',NULL,' Cliente 49 ');
 PERFORM set_config('app.current_operation','digital_sales.storefront.customer.read',true);
 saved:=ventas_digitales.cliente_metodos_pago_leer('https://issuer.example.invalid','customer-sub-49','qa49.example.invalid');
 IF jsonb_array_length(saved)<>2
  OR NOT saved @> '[{"method":"mobile","bankCode":"0134","document":"V87654321","phone":"04149876543"}]'
  OR NOT saved @> '[{"method":"transfer","bankCode":"0105","document":"J123456789","holder":"Cliente 49"}]' THEN
  RAISE EXCEPTION 'Saved payment methods mismatch: %',saved;END IF;
 BEGIN
  PERFORM ventas_digitales.cliente_metodos_pago_leer('https://issuer.example.invalid','customer-sub-49','other.example.invalid');
  RAISE EXCEPTION 'Payment methods leaked across stores';
 EXCEPTION WHEN no_data_found THEN NULL;
 END;
END $$;
RESET ROLE;
DO $$ BEGIN
 IF has_table_privilege('mastererp_app','ventas_digitales.cliente_metodos_pago','SELECT,INSERT,UPDATE,DELETE') THEN
  RAISE EXCEPTION 'Direct payment method DML leaked';END IF;
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
