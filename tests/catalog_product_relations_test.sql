BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-product-rel','Product relations fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code) SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p WHERE r.code='qa-product-rel' AND p.code IN('catalog.products.read','catalog.products.write','catalog.brands.read','catalog.brands.write','catalog.suppliers.read','catalog.suppliers.write');
INSERT INTO plataforma.users(id,email,display_name) VALUES('00009101-0000-0000-0000-000000000001','qa-rel@example.invalid','Relations');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00009102-0000-0000-0000-000000000001','qa-rel','qa-rel','Relations','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status) SELECT '00009102-0000-0000-0000-000000000001','00009101-0000-0000-0000-000000000001',id,'active' FROM plataforma.roles WHERE code='qa-product-rel';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status) SELECT '00009102-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code='erp.catalog';
SELECT set_config('app.current_user_id','00009101-0000-0000-0000-000000000001',true),set_config('app.current_tenant_id','00009102-0000-0000-0000-000000000001',true),set_config('app.correlation_id','00009103-0000-0000-0000-000000000001',true),set_config('app.current_operation','catalog.brands.create',true);SET LOCAL ROLE mastererp_app;
DO $$ DECLARE product jsonb;supplier jsonb;relations jsonb;BEGIN
 PERFORM catalogo.marca_crear('acme','ACME','','/images/acme.png',NULL,'rel-brand');
 PERFORM set_config('app.current_operation','catalog.suppliers.create',true);supplier:=catalogo.proveedor_crear('SUP-R','Proveedor relación','{}','{}','rel-supplier');
 PERFORM set_config('app.current_operation','catalog.products.create',true);product:=catalogo.producto_crear('Producto relación','',10,'ACTIVE',NULL,NULL,'{}',NULL,'rel-product');
 relations:=catalogo.producto_relaciones_actualizar((product->>'id')::uuid,1,'acme',jsonb_build_array(jsonb_build_object('id',supplier->>'id','supplier_code','X-1','cost',7,'lead_days',3,'preferred',true)));
 IF relations->>'brand_ref'<>'acme' OR jsonb_array_length(relations->'suppliers')<>1 OR (relations->>'version')::int<>2 THEN RAISE EXCEPTION 'Relation mismatch';END IF;
 IF has_table_privilege('mastererp_app','catalogo.producto_proveedores','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Direct relation DML leaked';END IF;
END $$;ROLLBACK;
