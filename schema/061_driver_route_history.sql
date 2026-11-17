-- Preserve the driver's route history after the active route is closed.
CREATE OR REPLACE FUNCTION operaciones.ruta_respuesta(p_tenant uuid,p_empresa uuid,p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,operaciones,ventas_digitales,pg_temp AS $$
 SELECT jsonb_build_object(
  'id',r.id,'node_id',r.nodo_id,'driver_id',r.repartidor_id,'date',r.fecha,
  'status',r.estado,'delivery_window_ref',r.ventana_ref,'version',r.version,
  'created_at',r.creado_en,'updated_at',r.actualizado_en,
  'stops',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
   'order_id',s.pedido_id,'order_number',p.numero,'sequence',s.secuencia,'status',s.estado,
   'delivery',p.entrega_snapshot,'customer',jsonb_build_object(
    'name',p.cliente_snapshot->>'name','phone',COALESCE(NULLIF(p.cliente_snapshot->>'phone',''),profile.telefono)),
   'items',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',line.id,'product_id',line.producto_id,'name',line.producto_nombre,
    'quantity',line.cantidad,'position',line.posicion) ORDER BY line.posicion),'[]')
    FROM operaciones.pedido_lineas line
    WHERE (line.tenant_id,line.empresa_id,line.pedido_id)=(p.tenant_id,p.empresa_id,p.id)),
   'evidence',s.evidencia,'updated_at',s.actualizado_en) ORDER BY s.secuencia),'[]')
   FROM operaciones.ruta_paradas s JOIN operaciones.pedidos p
    ON (p.tenant_id,p.empresa_id,p.id)=(s.tenant_id,s.empresa_id,s.pedido_id)
   LEFT JOIN ventas_digitales.cliente_perfiles profile
    ON (profile.tenant_id,profile.empresa_id,profile.cliente_id)=(p.tenant_id,p.empresa_id,p.cliente_id)
   WHERE (s.tenant_id,s.empresa_id,s.ruta_id)=(r.tenant_id,r.empresa_id,r.id)))
 FROM operaciones.rutas r WHERE r.tenant_id=p_tenant AND r.empresa_id=p_empresa AND r.id=p_id
$$;

CREATE OR REPLACE FUNCTION operaciones.ruta_repartidor_actual(p_empresa uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,transporte,plataforma,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 driver transporte.repartidores%ROWTYPE; active_route operaciones.rutas%ROWTYPE; history jsonb;
BEGIN
 IF plataforma.has_current_tenant_capability('erp.transport','transport.deliveries.execute',p_empresa) IS NOT TRUE THEN
  RAISE EXCEPTION 'Driver delivery denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO driver FROM transporte.repartidores
 WHERE tenant_id=tenant AND usuario_id=actor AND estado='ACTIVE' AND acceso_estado='LINKED';
 IF NOT FOUND THEN RAISE EXCEPTION 'Linked driver required' USING ERRCODE='42501'; END IF;
 SELECT * INTO active_route FROM operaciones.rutas WHERE tenant_id=tenant AND empresa_id=p_empresa
  AND repartidor_id=driver.id AND estado IN('ASSIGNED','IN_ROUTE')
  ORDER BY CASE estado WHEN 'IN_ROUTE' THEN 0 ELSE 1 END,fecha DESC,actualizado_en DESC LIMIT 1;
 SELECT COALESCE(jsonb_agg(operaciones.ruta_respuesta(tenant,p_empresa,q.id)
  ORDER BY q.fecha DESC,q.actualizado_en DESC),'[]') INTO history
 FROM (SELECT id,fecha,actualizado_en FROM operaciones.rutas
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND repartidor_id=driver.id
   AND estado IN('COMPLETED','CANCELLED') ORDER BY fecha DESC,actualizado_en DESC LIMIT 50) q;
 RETURN jsonb_build_object('driver_id',driver.id,
  'route',CASE WHEN active_route.id IS NULL THEN NULL ELSE operaciones.ruta_respuesta(tenant,p_empresa,active_route.id) END,
  'routes',history);
END $$;

REVOKE ALL ON FUNCTION operaciones.ruta_respuesta(uuid,uuid,uuid),
 operaciones.ruta_repartidor_actual(uuid) FROM PUBLIC,mastererp_app;
GRANT EXECUTE ON FUNCTION operaciones.ruta_repartidor_actual(uuid) TO mastererp_app;
