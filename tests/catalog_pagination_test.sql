BEGIN;
INSERT INTO plataforma.roles(code,name)VALUES('qa-catalog-page','Catalog pagination fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code)SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p WHERE r.code='qa-catalog-page' AND p.code LIKE 'catalog.%';
INSERT INTO plataforma.users(id,email,display_name)VALUES('00009201-0000-0000-0000-000000000001','qa-page@example.invalid','Catalog Page');
INSERT INTO plataforma.tenants(id,code,slug,name,status)VALUES('00009202-0000-0000-0000-000000000001','qa-page','qa-page','Catalog Page','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)SELECT '00009202-0000-0000-0000-000000000001','00009201-0000-0000-0000-000000000001',id,'active'FROM plataforma.roles WHERE code='qa-catalog-page';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)SELECT '00009202-0000-0000-0000-000000000001',id,'active'FROM plataforma.modules WHERE code='erp.catalog';
SELECT set_config('app.current_user_id','00009201-0000-0000-0000-000000000001',true),set_config('app.current_tenant_id','00009202-0000-0000-0000-000000000001',true),set_config('app.correlation_id','00009203-0000-0000-0000-000000000001',true),set_config('app.current_operation','catalog.products.create',true);SET LOCAL ROLE mastererp_app;
DO $$DECLARE page jsonb;BEGIN
 PERFORM catalogo.producto_crear('Producto A','',1,'ACTIVE',NULL,NULL,'{}',NULL,'page-a');PERFORM catalogo.producto_crear('Producto B','',2,'ACTIVE',NULL,NULL,'{}',NULL,'page-b');
 page:=catalogo.productos_pagina('ACTIVE','Producto',1,1);
 IF page->>'total'<>'2' OR jsonb_array_length(page->'items')<>1 OR page->>'offset'<>'1' THEN RAISE EXCEPTION 'Product pagination mismatch';END IF;
 IF (catalogo.categorias_pagina(NULL,NULL,25,0)->>'total')::int<>0 OR (catalogo.atributos_pagina(NULL,NULL,25,0)->>'total')::int<>0 OR (catalogo.marcas_pagina(NULL,NULL,25,0)->>'total')::int<>0 OR (catalogo.proveedores_pagina(NULL,NULL,25,0)->>'total')::int<>0 THEN RAISE EXCEPTION 'Empty directory pagination mismatch';END IF;
END $$;ROLLBACK;
