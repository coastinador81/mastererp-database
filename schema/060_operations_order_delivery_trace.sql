-- Make route outcomes and controlled historical-address corrections part of the
-- immutable order trace and authorized read model.
INSERT INTO plataforma.permissions(code,description) VALUES
 ('operations.orders.address.correct','Correct a historical order delivery address')
ON CONFLICT(code) DO NOTHING;

INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='tenant.owner' AND p.code='operations.orders.address.correct'
ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION operaciones.pedido_entrega_evento_registrar()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id();
 correlation uuid:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
BEGIN
 IF OLD.estado='PENDING' AND NEW.estado IN('DELIVERED','FAILED') THEN
  IF actor IS NULL OR correlation IS NULL THEN
   RAISE EXCEPTION 'Delivery trace context required' USING ERRCODE='22023';
  END IF;
  INSERT INTO operaciones.pedido_eventos(
   tenant_id,empresa_id,pedido_id,estado_anterior,estado_nuevo,motivo,detalle,actor_id,correlation_id,creado_en)
  VALUES(NEW.tenant_id,NEW.empresa_id,NEW.pedido_id,'OUT_FOR_DELIVERY',
   CASE NEW.estado WHEN 'DELIVERED' THEN 'DELIVERED' ELSE 'READY' END,
   CASE NEW.estado WHEN 'DELIVERED' THEN 'DELIVERY_COMPLETED' ELSE 'DELIVERY_FAILED' END,
   CASE WHEN NEW.estado='FAILED' THEN NULLIF(btrim(NEW.evidencia->>'reason'),'') END,
   actor,correlation,clock_timestamp());
 END IF;
 RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION operaciones.pedido_entrega_evento_registrar() FROM PUBLIC,mastererp_app;
DROP TRIGGER IF EXISTS ruta_parada_pedido_evento ON operaciones.ruta_paradas;
CREATE TRIGGER ruta_parada_pedido_evento
 AFTER UPDATE OF estado ON operaciones.ruta_paradas
 FOR EACH ROW EXECUTE FUNCTION operaciones.pedido_entrega_evento_registrar();

CREATE OR REPLACE FUNCTION operaciones.pedido_direccion_corregir(
 p_empresa uuid,p_pedido uuid,p_version bigint,p_direccion text,
 p_latitud numeric,p_longitud numeric,p_motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 current operaciones.pedidos%ROWTYPE; correlation uuid;
 operation text:='operations.orders.address.correct'; next_snapshot jsonb;
BEGIN
 IF p_empresa IS NULL OR p_pedido IS NULL OR p_version IS NULL
  OR length(btrim(COALESCE(p_direccion,''))) NOT BETWEEN 5 AND 500
  OR p_latitud IS NULL OR p_latitud NOT BETWEEN -90 AND 90
  OR p_longitud IS NULL OR p_longitud NOT BETWEEN -180 AND 180
  OR length(btrim(COALESCE(p_motivo,''))) NOT BETWEEN 3 AND 500 THEN
  RAISE EXCEPTION 'Invalid address correction' USING ERRCODE='22023';
 END IF;
 IF plataforma.has_current_tenant_capability(
  'erp.operations','operations.orders.address.correct',p_empresa) IS NOT TRUE THEN
  RAISE EXCEPTION 'Order address correction denied' USING ERRCODE='42501';
 END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM operation THEN
  RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501';
 END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF actor IS NULL OR correlation IS NULL THEN
  RAISE EXCEPTION 'Correction context required' USING ERRCODE='22023';
 END IF;
 SELECT * INTO current FROM operaciones.pedidos
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 IF current.version<>p_version THEN
  RAISE EXCEPTION 'Stale order version' USING ERRCODE='40001'; END IF;
 IF current.estado NOT IN('PENDING','CONFIRMED','PREPARING','READY')
  OR current.ruta_ref IS NOT NULL
  OR EXISTS(SELECT 1 FROM operaciones.ruta_paradas s
   JOIN operaciones.rutas r ON (r.tenant_id,r.empresa_id,r.id)=(s.tenant_id,s.empresa_id,s.ruta_id)
   WHERE s.tenant_id=tenant AND s.empresa_id=p_empresa AND s.pedido_id=p_pedido
    AND s.estado='PENDING' AND r.estado IN('ASSIGNED','IN_ROUTE')) THEN
  RAISE EXCEPTION 'Order address cannot be corrected in its current state' USING ERRCODE='23514';
 END IF;
 next_snapshot:=current.entrega_snapshot||jsonb_build_object(
  'address',btrim(p_direccion),'latitude',p_latitud,'longitude',p_longitud);
 UPDATE operaciones.pedidos SET entrega_snapshot=next_snapshot,version=version+1,
  actualizado_en=transaction_timestamp() WHERE id=p_pedido;
 INSERT INTO operaciones.pedido_eventos(
  tenant_id,empresa_id,pedido_id,estado_anterior,estado_nuevo,motivo,detalle,actor_id,correlation_id,creado_en)
 VALUES(tenant,p_empresa,p_pedido,current.estado,current.estado,'DELIVERY_ADDRESS_CORRECTED',
  btrim(p_motivo),actor,correlation,clock_timestamp());
 INSERT INTO auditoria.events(
  tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.3.1-orders','pedido',p_pedido,operation,correlation,
  jsonb_build_object('empresa_id',p_empresa,'estado',current.estado,'motivo',btrim(p_motivo),
   'resultado','succeeded'));
 RETURN operaciones.pedidos_leer(p_empresa,p_pedido);
END $$;

CREATE OR REPLACE FUNCTION operaciones.pedidos_leer(
 p_empresa uuid,p_id uuid DEFAULT NULL,p_estado text DEFAULT NULL,
 p_limit integer DEFAULT 25,p_after timestamptz DEFAULT NULL,p_after_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,transporte,plataforma,organizacion,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_empresa IS NULL OR p_limit NOT BETWEEN 1 AND 101
 OR (p_estado IS NOT NULL AND p_estado NOT IN ('PENDING','CONFIRMED','PREPARING','READY','OUT_FOR_DELIVERY','DELIVERED','CANCELLED'))
 OR ((p_after IS NULL)<>(p_after_id IS NULL)) THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.orders.read',p_empresa) IS NOT TRUE THEN
  RAISE EXCEPTION 'Order access denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(item ORDER BY creado_en DESC,id DESC),'[]') INTO result FROM (
  SELECT p.id,p.creado_en,jsonb_build_object(
   'id',p.id,'company_id',p.empresa_id,'branch_id',p.sucursal_id,'customer_id',p.cliente_id,
   'number',p.numero,'status',p.estado,'currency',p.moneda,'subtotal',p.subtotal,
   'delivery_fee',p.tarifa_entrega,'total',p.total,'customer_snapshot',p.cliente_snapshot,
   'delivery_snapshot',p.entrega_snapshot,'payment_snapshot',p.pago_snapshot,
   'delivery_window_ref',p.ventana_entrega_ref,'delivery_method',p.metodo_entrega,
   'route_ref',p.ruta_ref,'external_reference',p.referencia_externa,
   'created_at',p.creado_en,'updated_at',p.actualizado_en,'version',p.version,
   'items',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',l.id,'position',l.posicion,
    'product_id',l.producto_id,'product_name',l.producto_nombre,'quantity',l.cantidad,
    'unit_price',l.precio_unitario,'subtotal',l.subtotal) ORDER BY l.posicion),'[]')
    FROM operaciones.pedido_lineas l WHERE l.pedido_id=p.id),
   'history',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',e.id,'previous_status',e.estado_anterior,'status',e.estado_nuevo,
    'reason',e.motivo,'detail',e.detalle,'actor_id',e.actor_id,
    'actor_name',u.display_name,'created_at',e.creado_en)
    ORDER BY e.creado_en,e.id),'[]')
    FROM operaciones.pedido_eventos e JOIN plataforma.users u ON u.id=e.actor_id
    WHERE e.tenant_id=p.tenant_id AND e.empresa_id=p.empresa_id AND e.pedido_id=p.id),
   'delivery_attempts',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'route_id',s.ruta_id,'route_date',r.fecha,'stop_sequence',s.secuencia,'status',s.estado,
    'driver_id',d.id,'driver_name',d.nombre,
    'evidence',s.evidencia,'updated_at',s.actualizado_en)
    ORDER BY s.actualizado_en,s.ruta_id),'[]')
    FROM operaciones.ruta_paradas s JOIN operaciones.rutas r
     ON (r.tenant_id,r.empresa_id,r.id)=(s.tenant_id,s.empresa_id,s.ruta_id)
    LEFT JOIN transporte.repartidores d
     ON (d.tenant_id,d.id)=(r.tenant_id,r.repartidor_id)
    WHERE s.tenant_id=p.tenant_id AND s.empresa_id=p.empresa_id
     AND s.pedido_id=p.id AND s.estado IN('DELIVERED','FAILED'))
  ) item FROM operaciones.pedidos p
  WHERE p.tenant_id=plataforma.current_app_tenant_id() AND p.empresa_id=p_empresa
  AND (p_id IS NULL OR p.id=p_id) AND (p_estado IS NULL OR p.estado=p_estado)
  AND (p_after IS NULL OR (p.creado_en,p.id)<(p_after,p_after_id))
  ORDER BY p.creado_en DESC,p.id DESC LIMIT p_limit
 ) q;
 IF p_id IS NOT NULL AND jsonb_array_length(result)=0 THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 RETURN CASE WHEN p_id IS NULL THEN result ELSE result->0 END;
END $$;

REVOKE ALL ON FUNCTION operaciones.pedidos_leer(uuid,uuid,text,integer,timestamptz,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION operaciones.pedido_direccion_corregir(uuid,uuid,bigint,text,numeric,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operaciones.pedidos_leer(uuid,uuid,text,integer,timestamptz,uuid),
 operaciones.pedido_direccion_corregir(uuid,uuid,bigint,text,numeric,numeric,text) TO mastererp_app;
