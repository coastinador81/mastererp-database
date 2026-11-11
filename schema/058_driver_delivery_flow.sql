-- Driver-owned delivery command with automatic route completion.
INSERT INTO plataforma.permissions(code,description) VALUES
 ('transport.deliveries.execute','Complete assigned delivery stops as the linked driver')
ON CONFLICT(code) DO NOTHING;

INSERT INTO plataforma.roles(code,name) VALUES('tenant.driver','Repartidor') ON CONFLICT(code) DO NOTHING;
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='tenant.driver' AND p.code='transport.deliveries.execute' ON CONFLICT DO NOTHING;
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='tenant.owner' AND p.code='transport.deliveries.execute' ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION operaciones.ruta_respuesta(p_tenant uuid,p_empresa uuid,p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,operaciones,pg_temp AS $$
 SELECT jsonb_build_object(
  'id',r.id,'node_id',r.nodo_id,'driver_id',r.repartidor_id,'date',r.fecha,
  'status',r.estado,'delivery_window_ref',r.ventana_ref,'version',r.version,
  'stops',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
   'order_id',s.pedido_id,'sequence',s.secuencia,'status',s.estado,
   'delivery',p.entrega_snapshot,'customer',jsonb_build_object(
    'name',p.cliente_snapshot->>'name','phone',p.cliente_snapshot->>'phone'),
   'evidence',s.evidencia,'updated_at',s.actualizado_en) ORDER BY s.secuencia),'[]')
   FROM operaciones.ruta_paradas s JOIN operaciones.pedidos p
    ON (p.tenant_id,p.empresa_id,p.id)=(s.tenant_id,s.empresa_id,s.pedido_id)
   WHERE (s.tenant_id,s.empresa_id,s.ruta_id)=(r.tenant_id,r.empresa_id,r.id)))
 FROM operaciones.rutas r WHERE r.tenant_id=p_tenant AND r.empresa_id=p_empresa AND r.id=p_id
$$;

REVOKE ALL ON FUNCTION operaciones.ruta_respuesta(uuid,uuid,uuid) FROM PUBLIC,mastererp_app;

CREATE OR REPLACE FUNCTION operaciones.ruta_repartidor_actual(p_empresa uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,transporte,plataforma,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 driver transporte.repartidores%ROWTYPE; route operaciones.rutas%ROWTYPE;
BEGIN
 IF plataforma.has_current_tenant_capability('erp.transport','transport.deliveries.execute',p_empresa) IS NOT TRUE THEN
  RAISE EXCEPTION 'Driver delivery denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO driver FROM transporte.repartidores
 WHERE tenant_id=tenant AND usuario_id=actor AND estado='ACTIVE' AND acceso_estado='LINKED';
 IF NOT FOUND THEN RAISE EXCEPTION 'Linked driver required' USING ERRCODE='42501'; END IF;
 SELECT * INTO route FROM operaciones.rutas WHERE tenant_id=tenant AND empresa_id=p_empresa
 AND repartidor_id=driver.id AND estado IN('ASSIGNED','IN_ROUTE') ORDER BY fecha DESC,actualizado_en DESC LIMIT 1;
 IF NOT FOUND THEN RETURN jsonb_build_object('driver_id',driver.id,'route',NULL); END IF;
 RETURN jsonb_build_object('driver_id',driver.id,'route',operaciones.ruta_respuesta(tenant,p_empresa,route.id));
END $$;

CREATE OR REPLACE FUNCTION operaciones.ruta_entrega_registrar(
 p_empresa uuid,p_ruta uuid,p_pedido uuid,p_estado text,p_evidencia jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,transporte,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 driver transporte.repartidores%ROWTYPE; route operaciones.rutas%ROWTYPE; order_row operaciones.pedidos%ROWTYPE;
 stop_row operaciones.ruta_paradas%ROWTYPE; latitude double precision; longitude double precision;
 accuracy double precision; destination_lat double precision; destination_lon double precision;
 distance_m double precision; completed boolean; correlation uuid;
BEGIN
 IF p_estado NOT IN('DELIVERED','FAILED') OR jsonb_typeof(p_evidencia)<>'object' THEN
  RAISE EXCEPTION 'Invalid delivery result' USING ERRCODE='22023'; END IF;
 SELECT * INTO driver FROM transporte.repartidores
 WHERE tenant_id=tenant AND usuario_id=actor AND estado='ACTIVE' AND acceso_estado='LINKED' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Linked driver required' USING ERRCODE='42501'; END IF;
 SELECT * INTO route FROM operaciones.rutas WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_ruta FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Route not found' USING ERRCODE='P0002'; END IF;
 IF route.repartidor_id<>driver.id OR
  plataforma.has_current_tenant_capability('erp.transport','transport.deliveries.execute',p_empresa,route.nodo_id) IS NOT TRUE THEN
  RAISE EXCEPTION 'Driver route denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO stop_row FROM operaciones.ruta_paradas WHERE tenant_id=tenant AND empresa_id=p_empresa
 AND ruta_id=p_ruta AND pedido_id=p_pedido FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Stop not found' USING ERRCODE='P0002'; END IF;
 IF stop_row.estado<>'PENDING' THEN
  RETURN jsonb_build_object('route',operaciones.ruta_respuesta(tenant,p_empresa,p_ruta),
   'route_completed',route.estado='COMPLETED','idempotent',true); END IF;
 IF route.estado<>'IN_ROUTE' THEN
  RAISE EXCEPTION 'Driver route is not active' USING ERRCODE='23514'; END IF;
 SELECT * INTO order_row FROM operaciones.pedidos WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido FOR UPDATE;
 IF order_row.estado<>'OUT_FOR_DELIVERY' OR order_row.ruta_ref<>p_ruta::text THEN
  RAISE EXCEPTION 'Order is not on driver route' USING ERRCODE='23514'; END IF;
 IF p_estado='DELIVERED' THEN
  BEGIN
   latitude:=(p_evidencia->>'latitude')::double precision; longitude:=(p_evidencia->>'longitude')::double precision;
   accuracy:=(p_evidencia->>'accuracy_meters')::double precision;
   destination_lat:=(order_row.entrega_snapshot->>'latitude')::double precision;
   destination_lon:=(order_row.entrega_snapshot->>'longitude')::double precision;
  EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'Valid GPS evidence required' USING ERRCODE='22023'; END;
  IF latitude NOT BETWEEN -90 AND 90 OR longitude NOT BETWEEN -180 AND 180 OR accuracy<=0 OR accuracy>100
   OR destination_lat NOT BETWEEN -90 AND 90 OR destination_lon NOT BETWEEN -180 AND 180 THEN
   RAISE EXCEPTION 'Valid GPS evidence required' USING ERRCODE='22023'; END IF;
  distance_m:=6371000*2*asin(sqrt(least(1,greatest(0,
   sin(radians(destination_lat-latitude)/2)^2+cos(radians(latitude))*cos(radians(destination_lat))*
   sin(radians(destination_lon-longitude)/2)^2))));
  IF distance_m>250 THEN RAISE EXCEPTION 'Delivery outside allowed radius' USING ERRCODE='23514'; END IF;
  p_evidencia:=p_evidencia||jsonb_build_object('method','DRIVER_GPS','distance_meters',round(distance_m::numeric,1),
   'driver_id',driver.id,'recorded_at',transaction_timestamp());
 ELSE
  IF length(btrim(COALESCE(p_evidencia->>'reason',''))) NOT BETWEEN 1 AND 500 THEN
   RAISE EXCEPTION 'Failure reason required' USING ERRCODE='22023'; END IF;
  p_evidencia:=p_evidencia||jsonb_build_object('driver_id',driver.id,'recorded_at',transaction_timestamp());
 END IF;
 UPDATE operaciones.ruta_paradas SET estado=p_estado,evidencia=p_evidencia,actualizado_en=transaction_timestamp()
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND ruta_id=p_ruta AND pedido_id=p_pedido;
 IF p_estado='DELIVERED' THEN
  UPDATE operaciones.pedidos SET estado='DELIVERED',version=version+1,actualizado_en=transaction_timestamp()
   WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido;
 ELSE
  UPDATE operaciones.pedidos SET estado='READY',ruta_ref=NULL,version=version+1,actualizado_en=transaction_timestamp()
   WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido;
 END IF;
 completed:=NOT EXISTS(SELECT 1 FROM operaciones.ruta_paradas WHERE tenant_id=tenant AND empresa_id=p_empresa
  AND ruta_id=p_ruta AND estado='PENDING');
 IF completed THEN
  UPDATE operaciones.rutas SET estado='COMPLETED',version=version+1,actualizado_en=transaction_timestamp()
   WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_ruta;
  UPDATE transporte.repartidores SET disponibilidad='AVAILABLE',version=version+1,actualizado_en=transaction_timestamp()
   WHERE tenant_id=tenant AND id=driver.id;
 END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.10.5-routes','ruta_parada',p_pedido,'transport.deliveries.execute',correlation,
  jsonb_build_object('empresa_id',p_empresa,'ruta_id',p_ruta,'estado',p_estado,'ruta_completada',completed,'resultado','succeeded'));
 RETURN jsonb_build_object('route',operaciones.ruta_respuesta(tenant,p_empresa,p_ruta),
  'route_completed',completed,'idempotent',false);
END $$;

CREATE OR REPLACE FUNCTION operaciones.ruta_repartidor_tienda(p_dominio text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,ventas_digitales,plataforma,pg_temp AS $$
DECLARE company uuid;
BEGIN
 SELECT empresa_id INTO company FROM ventas_digitales.tiendas
 WHERE tenant_id=plataforma.current_app_tenant_id() AND lower(dominio)=lower(p_dominio) AND estado='ACTIVE';
 IF NOT FOUND THEN RAISE EXCEPTION 'Store not found' USING ERRCODE='P0002'; END IF;
 RETURN operaciones.ruta_repartidor_actual(company);
END $$;

CREATE OR REPLACE FUNCTION operaciones.ruta_entrega_tienda(
 p_dominio text,p_ruta uuid,p_pedido uuid,p_estado text,p_evidencia jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,ventas_digitales,plataforma,pg_temp AS $$
DECLARE company uuid;
BEGIN
 SELECT empresa_id INTO company FROM ventas_digitales.tiendas
 WHERE tenant_id=plataforma.current_app_tenant_id() AND lower(dominio)=lower(p_dominio) AND estado='ACTIVE';
 IF NOT FOUND THEN RAISE EXCEPTION 'Store not found' USING ERRCODE='P0002'; END IF;
 RETURN operaciones.ruta_entrega_registrar(company,p_ruta,p_pedido,p_estado,p_evidencia);
END $$;

REVOKE ALL ON FUNCTION operaciones.ruta_repartidor_actual(uuid),
 operaciones.ruta_entrega_registrar(uuid,uuid,uuid,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operaciones.ruta_repartidor_actual(uuid),
 operaciones.ruta_entrega_registrar(uuid,uuid,uuid,text,jsonb) TO mastererp_app;
REVOKE ALL ON FUNCTION operaciones.ruta_repartidor_tienda(text),
 operaciones.ruta_entrega_tienda(text,uuid,uuid,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operaciones.ruta_repartidor_tienda(text),
 operaciones.ruta_entrega_tienda(text,uuid,uuid,text,jsonb) TO mastererp_app;
