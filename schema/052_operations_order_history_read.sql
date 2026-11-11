-- Expose the existing immutable order events through the authorized order read model.
CREATE OR REPLACE FUNCTION operaciones.pedidos_leer(
 p_empresa uuid,p_id uuid DEFAULT NULL,p_estado text DEFAULT NULL,
 p_limit integer DEFAULT 25,p_after timestamptz DEFAULT NULL,p_after_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,organizacion,pg_temp AS $$
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
    FROM operaciones.pedido_eventos e
    JOIN plataforma.users u ON u.id=e.actor_id
    WHERE e.tenant_id=p.tenant_id AND e.empresa_id=p.empresa_id AND e.pedido_id=p.id)
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
GRANT EXECUTE ON FUNCTION operaciones.pedidos_leer(uuid,uuid,text,integer,timestamptz,uuid) TO mastererp_app;
