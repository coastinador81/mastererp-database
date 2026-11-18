BEGIN;
INSERT INTO plataforma.roles(code,name)VALUES('qa-inventory-visible','Inventory visibility fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code)SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p WHERE r.code='qa-inventory-visible'AND p.code IN('catalog.inventory.read','catalog.inventory.write','operations.nodes.read','operations.nodes.write');
INSERT INTO plataforma.users(id,email,display_name)VALUES('00009301-0000-0000-0000-000000000001','qa-inventory-visible@example.invalid','Inventory Visible');
INSERT INTO plataforma.tenants(id,code,slug,name,status)VALUES('00009302-0000-0000-0000-000000000001','qa-inventory-visible','qa-inventory-visible','Inventory Visible','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)SELECT '00009302-0000-0000-0000-000000000001','00009301-0000-0000-0000-000000000001',id,'active'FROM plataforma.roles WHERE code='qa-inventory-visible';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)SELECT '00009302-0000-0000-0000-000000000001',id,'active'FROM plataforma.modules WHERE code IN('erp.catalog','erp.operations');
INSERT INTO catalogo.monedas(codigo,nombre,decimales)VALUES('USD','US dollar',2)ON CONFLICT DO NOTHING;
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)VALUES('00009303-0000-0000-0000-000000000001','00009302-0000-0000-0000-000000000001','Fixture','VE','USD','America/Caracas');
INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code,status)VALUES('00009304-0000-0000-0000-000000000001','00009302-0000-0000-0000-000000000001','00009303-0000-0000-0000-000000000001','MAIN','Main node','warehouse','VE','active');
INSERT INTO catalogo.productos(id,tenant_id,codigo,nombre,precio,estado)VALUES('00009305-0000-0000-0000-000000000001','00009302-0000-0000-0000-000000000001','PRD-NEW','New catalog product',10,'ACTIVE');
SELECT set_config('app.current_user_id','00009301-0000-0000-0000-000000000001',true),set_config('app.current_tenant_id','00009302-0000-0000-0000-000000000001',true),set_config('app.current_company_id','00009303-0000-0000-0000-000000000001',true),set_config('app.correlation_id','00009306-0000-0000-0000-000000000001',true),set_config('app.current_operation','operations.nodes.configure',true);SET LOCAL ROLE mastererp_app;
DO $$DECLARE item jsonb;BEGIN
 PERFORM operaciones.nodo_configurar('00009303-0000-0000-0000-000000000001','00009304-0000-0000-0000-000000000001','{"accepts_orders":true,"coverage_radius_km":5,"daily_capacity":100}');
 PERFORM set_config('app.current_operation','catalog.inventory.read',true);
 item:=catalogo.inventario_leer('00009303-0000-0000-0000-000000000001','00009304-0000-0000-0000-000000000001','00009305-0000-0000-0000-000000000001');
 IF item->>'initialized'<>'false'OR item->>'stock'<>'0'OR item->>'version'<>'0' THEN RAISE EXCEPTION 'Uninitialized product is not visible';END IF;
END $$;ROLLBACK;
