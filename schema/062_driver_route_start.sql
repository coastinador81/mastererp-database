-- Let a linked driver start only their own assigned route.
INSERT INTO plataforma.permissions(code,description) VALUES
 ('transport.routes.start','Start the route assigned to the linked driver')
ON CONFLICT(code) DO NOTHING;

INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT id,'transport.routes.start' FROM plataforma.roles WHERE code IN('tenant.driver','tenant.owner')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION operaciones.ruta_repartidor_iniciar(p_empresa uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,transporte,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 driver transporte.repartidores%ROWTYPE; route operaciones.rutas%ROWTYPE; correlation uuid;
BEGIN
 IF plataforma.has_current_tenant_capability('erp.transport','transport.routes.start',p_empresa) IS NOT TRUE
  OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'transport.routes.start' THEN
  RAISE EXCEPTION 'Driver route start denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO driver FROM transporte.repartidores
  WHERE tenant_id=tenant AND usuario_id=actor AND estado='ACTIVE' AND acceso_estado='LINKED' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Linked driver required' USING ERRCODE='42501'; END IF;
 SELECT * INTO route FROM operaciones.rutas WHERE tenant_id=tenant AND empresa_id=p_empresa
  AND repartidor_id=driver.id AND estado IN('ASSIGNED','IN_ROUTE')
  ORDER BY CASE estado WHEN 'IN_ROUTE' THEN 0 ELSE 1 END,fecha DESC,actualizado_en DESC LIMIT 1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Assigned driver route required' USING ERRCODE='23514'; END IF;
 IF route.estado='IN_ROUTE' THEN RETURN operaciones.ruta_repartidor_actual(p_empresa); END IF;
 UPDATE operaciones.rutas SET estado='IN_ROUTE',version=version+1,actualizado_en=transaction_timestamp()
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=route.id AND estado='ASSIGNED';
 UPDATE operaciones.pedidos p SET estado='OUT_FOR_DELIVERY',version=version+1,actualizado_en=transaction_timestamp()
  FROM operaciones.ruta_paradas s WHERE (s.tenant_id,s.empresa_id,s.ruta_id)=(tenant,p_empresa,route.id)
   AND (p.tenant_id,p.empresa_id,p.id)=(s.tenant_id,s.empresa_id,s.pedido_id)
   AND p.estado='READY' AND p.ruta_ref=route.id::text;
 UPDATE transporte.repartidores SET disponibilidad='ON_ROUTE',version=version+1,actualizado_en=transaction_timestamp()
  WHERE tenant_id=tenant AND id=driver.id;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.10.5-routes','ruta',route.id,'transport.routes.start',correlation,
  jsonb_build_object('empresa_id',p_empresa,'repartidor_id',driver.id,'estado_anterior','ASSIGNED','estado','IN_ROUTE','resultado','succeeded'));
 RETURN operaciones.ruta_repartidor_actual(p_empresa);
END $$;

REVOKE ALL ON FUNCTION operaciones.ruta_repartidor_iniciar(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operaciones.ruta_repartidor_iniciar(uuid) TO mastererp_app;
