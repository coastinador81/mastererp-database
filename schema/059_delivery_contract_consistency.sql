-- Keep administrative and driver delivery results coordinated and expose legacy customer contact safely.
CREATE OR REPLACE FUNCTION operaciones.ruta_respuesta(p_tenant uuid,p_empresa uuid,p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,operaciones,ventas_digitales,pg_temp AS $$
 SELECT jsonb_build_object(
  'id',r.id,'node_id',r.nodo_id,'driver_id',r.repartidor_id,'date',r.fecha,
  'status',r.estado,'delivery_window_ref',r.ventana_ref,'version',r.version,
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

REVOKE ALL ON FUNCTION operaciones.ruta_respuesta(uuid,uuid,uuid) FROM PUBLIC,mastererp_app;

CREATE OR REPLACE FUNCTION operaciones.ruta_parada_finalizar(
 p_empresa uuid,p_ruta uuid,p_pedido uuid,p_estado text,p_evidencia jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,transporte,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 route operaciones.rutas%ROWTYPE; order_row operaciones.pedidos%ROWTYPE; completed boolean; correlation uuid;
BEGIN
 SELECT * INTO route FROM operaciones.rutas WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_ruta FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Route not found' USING ERRCODE='P0002'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.routes.write',p_empresa,route.nodo_id) IS NOT TRUE
  OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'operations.routes.stop.complete' THEN
  RAISE EXCEPTION 'Stop completion denied' USING ERRCODE='42501'; END IF;
 IF route.estado<>'IN_ROUTE' OR p_estado NOT IN('DELIVERED','FAILED') OR jsonb_typeof(p_evidencia)<>'object' THEN
  RAISE EXCEPTION 'Invalid stop state' USING ERRCODE='23514'; END IF;
 IF p_estado='FAILED' AND length(btrim(COALESCE(p_evidencia->>'reason',''))) NOT BETWEEN 1 AND 500 THEN
  RAISE EXCEPTION 'Failure reason required' USING ERRCODE='22023'; END IF;
 SELECT * INTO order_row FROM operaciones.pedidos WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido FOR UPDATE;
 IF NOT FOUND OR order_row.estado<>'OUT_FOR_DELIVERY' OR order_row.ruta_ref<>p_ruta::text THEN
  RAISE EXCEPTION 'Order is not on route' USING ERRCODE='23514'; END IF;
 UPDATE operaciones.ruta_paradas SET estado=p_estado,evidencia=p_evidencia,actualizado_en=transaction_timestamp()
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND ruta_id=p_ruta AND pedido_id=p_pedido AND estado='PENDING';
 IF NOT FOUND THEN RAISE EXCEPTION 'Stop not found' USING ERRCODE='P0002'; END IF;
 IF p_estado='DELIVERED' THEN
  UPDATE operaciones.pedidos SET estado='DELIVERED',version=version+1,actualizado_en=transaction_timestamp() WHERE id=p_pedido;
 ELSE
  UPDATE operaciones.pedidos SET estado='READY',ruta_ref=NULL,version=version+1,actualizado_en=transaction_timestamp() WHERE id=p_pedido;
 END IF;
 completed:=NOT EXISTS(SELECT 1 FROM operaciones.ruta_paradas
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND ruta_id=p_ruta AND estado='PENDING');
 IF completed THEN
  UPDATE operaciones.rutas SET estado='COMPLETED',version=version+1,actualizado_en=transaction_timestamp() WHERE id=p_ruta;
  UPDATE transporte.repartidores SET disponibilidad='AVAILABLE',version=version+1,actualizado_en=transaction_timestamp()
   WHERE tenant_id=tenant AND id=route.repartidor_id;
 END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.10.5-routes','ruta_parada',p_pedido,'operations.routes.stop.complete',correlation,
  jsonb_build_object('empresa_id',p_empresa,'ruta_id',p_ruta,'estado',p_estado,'ruta_completada',completed,'resultado','succeeded'));
 RETURN operaciones.ruta_respuesta(tenant,p_empresa,p_ruta);
END $$;

REVOKE ALL ON FUNCTION operaciones.ruta_parada_finalizar(uuid,uuid,uuid,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operaciones.ruta_parada_finalizar(uuid,uuid,uuid,text,jsonb) TO mastererp_app;
