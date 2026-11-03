BEGIN;
INSERT INTO plataforma.roles(code,name) VALUES('qa-drivers','Drivers fixture');
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='qa-drivers' AND p.code IN ('operations.nodes.read','operations.nodes.write','transport.drivers.read','transport.drivers.write','transport.drivers.assign');
INSERT INTO plataforma.users(id,email,display_name) VALUES('00006001-0000-0000-0000-000000000001','qa-drivers@example.invalid','Drivers test');
INSERT INTO plataforma.tenants(id,code,slug,name,status) VALUES('00006002-0000-0000-0000-000000000001','qa-drivers','qa-drivers','Drivers','active');
INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status)
 SELECT '00006002-0000-0000-0000-000000000001','00006001-0000-0000-0000-000000000001',id,'active' FROM plataforma.roles WHERE code='qa-drivers';
INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
 SELECT '00006002-0000-0000-0000-000000000001',id,'active' FROM plataforma.modules WHERE code IN ('erp.operations','erp.transport');
INSERT INTO catalogo.monedas(codigo,nombre,decimales) VALUES('USD','US dollar',2) ON CONFLICT DO NOTHING;
INSERT INTO organizacion.companies(id,tenant_id,legal_name,country_code,base_currency_code,timezone)
 VALUES('00006003-0000-0000-0000-000000000001','00006002-0000-0000-0000-000000000001','Drivers','US','USD','UTC');
INSERT INTO organizacion.branches(id,tenant_id,company_id,code,name,branch_type,country_code,status)
 VALUES('00006004-0000-0000-0000-000000000001','00006002-0000-0000-0000-000000000001','00006003-0000-0000-0000-000000000001','MAIN','Main','warehouse','US','active');
INSERT INTO operaciones.nodos(id,tenant_id,empresa_id,estado,acepta_pedidos,creado_por)
 VALUES('00006004-0000-0000-0000-000000000001','00006002-0000-0000-0000-000000000001','00006003-0000-0000-0000-000000000001','ACTIVE',true,'00006001-0000-0000-0000-000000000001');
SELECT set_config('app.current_user_id','00006001-0000-0000-0000-000000000001',true),
 set_config('app.current_tenant_id','00006002-0000-0000-0000-000000000001',true),
 set_config('app.correlation_id','00006005-0000-0000-0000-000000000001',true),
 set_config('app.current_operation','transport.drivers.create',true);
SET LOCAL ROLE mastererp_app;
DO $$ DECLARE item jsonb; replay jsonb; driver uuid; caught boolean:=false; BEGIN
 item:=transporte.repartidor_crear('00006003-0000-0000-0000-000000000001','Carlos Pérez','04140000000','carlos@example.invalid','{"type":"motorcycle"}','{"number":"LIC-1"}',NULL,'driver-create-key');
 driver:=(item->>'id')::uuid;
 replay:=transporte.repartidor_crear('00006003-0000-0000-0000-000000000001','Carlos Pérez','04140000000','carlos@example.invalid','{"type":"motorcycle"}','{"number":"LIC-1"}',NULL,'driver-create-key');
 IF replay->>'id'<>item->>'id' OR item->>'availability'<>'OFFLINE' THEN RAISE EXCEPTION 'Driver create/replay mismatch'; END IF;
 PERFORM set_config('app.current_operation','transport.drivers.update',true);
 item:=transporte.repartidor_actualizar('00006003-0000-0000-0000-000000000001',driver,1,'{"availability":"AVAILABLE","access_status":"LINKED"}');
 IF item->>'availability'<>'AVAILABLE' OR (item->>'version')::int<>2 THEN RAISE EXCEPTION 'Driver update mismatch'; END IF;
 BEGIN PERFORM transporte.repartidor_actualizar('00006003-0000-0000-0000-000000000001',driver,1,'{"name":"stale"}'); EXCEPTION WHEN serialization_failure THEN caught:=true; END;
 IF NOT caught THEN RAISE EXCEPTION 'Stale driver update accepted'; END IF;
 PERFORM set_config('app.current_operation','transport.drivers.assign',true);
 item:=transporte.repartidor_asignar_nodo('00006003-0000-0000-0000-000000000001','00006004-0000-0000-0000-000000000001',driver,true);
 IF jsonb_array_length(item->'node_ids')<>1 THEN RAISE EXCEPTION 'Driver node assignment mismatch'; END IF;
 IF has_table_privilege('mastererp_app','transporte.repartidores','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Direct driver DML leaked'; END IF;
END $$;
ROLLBACK;
