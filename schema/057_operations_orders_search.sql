-- Complete server-side order directory with keyset pagination and filters.
CREATE OR REPLACE FUNCTION operaciones.pedidos_listar(
 p_empresa uuid,p_estado text DEFAULT NULL,p_busqueda text DEFAULT NULL,p_pago text DEFAULT NULL,
 p_limit integer DEFAULT 25,p_desde date DEFAULT NULL,p_hasta date DEFAULT NULL,p_ascendente boolean DEFAULT false,
 p_after timestamptz DEFAULT NULL,p_after_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,organizacion,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_empresa IS NULL OR p_limit NOT BETWEEN 1 AND 100
 OR (p_estado IS NOT NULL AND p_estado NOT IN ('PENDING','CONFIRMED','PREPARING','READY','OUT_FOR_DELIVERY','DELIVERED','CANCELLED'))
 OR ((p_after IS NULL)<>(p_after_id IS NULL)) OR (p_desde IS NOT NULL AND p_hasta IS NOT NULL AND p_desde>p_hasta)
 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.orders.read',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Order access denied' USING ERRCODE='42501'; END IF;
 WITH filtered AS (
  SELECT p.* FROM operaciones.pedidos p
  JOIN organizacion.companies c ON c.tenant_id=p.tenant_id AND c.id=p.empresa_id
  WHERE p.tenant_id=plataforma.current_app_tenant_id() AND p.empresa_id=p_empresa
   AND (p_estado IS NULL OR p.estado=p_estado)
   AND (NULLIF(btrim(p_pago),'') IS NULL OR p.pago_snapshot->>'method'=p_pago)
   AND (p_desde IS NULL OR (p.creado_en AT TIME ZONE c.timezone)::date>=p_desde)
   AND (p_hasta IS NULL OR (p.creado_en AT TIME ZONE c.timezone)::date<=p_hasta)
   AND (NULLIF(btrim(p_busqueda),'') IS NULL OR position(lower(btrim(p_busqueda)) in lower(
    concat_ws(' ',p.numero,p.cliente_snapshot->>'name',p.cliente_snapshot->>'email',p.cliente_snapshot->>'phone'))) > 0)
   AND (p_after IS NULL OR (NOT p_ascendente AND (p.creado_en,p.id)<(p_after,p_after_id))
    OR (p_ascendente AND (p.creado_en,p.id)>(p_after,p_after_id)))
  ORDER BY CASE WHEN p_ascendente THEN p.creado_en END ASC,CASE WHEN NOT p_ascendente THEN p.creado_en END DESC,
   CASE WHEN p_ascendente THEN p.id END ASC,CASE WHEN NOT p_ascendente THEN p.id END DESC LIMIT p_limit+1
 ), page AS (SELECT * FROM filtered LIMIT p_limit),
 items AS (
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
    FROM operaciones.pedido_lineas l WHERE l.tenant_id=p.tenant_id AND l.empresa_id=p.empresa_id AND l.pedido_id=p.id)
  ) item FROM page p
 ), cursor_row AS (SELECT creado_en,id FROM page ORDER BY
   CASE WHEN p_ascendente THEN creado_en END DESC,CASE WHEN NOT p_ascendente THEN creado_en END ASC,
   CASE WHEN p_ascendente THEN id END DESC,CASE WHEN NOT p_ascendente THEN id END ASC LIMIT 1)
 SELECT jsonb_build_object(
  'items',COALESCE((SELECT jsonb_agg(item ORDER BY
   CASE WHEN p_ascendente THEN creado_en END ASC,CASE WHEN NOT p_ascendente THEN creado_en END DESC,
   CASE WHEN p_ascendente THEN id END ASC,CASE WHEN NOT p_ascendente THEN id END DESC) FROM items),'[]'),
  'next_cursor',CASE WHEN (SELECT count(*) FROM filtered)>p_limit THEN
   (SELECT jsonb_build_object('after',creado_en,'after_id',id) FROM cursor_row) ELSE NULL END)
 INTO result;
 RETURN result;
END $$;

REVOKE ALL ON FUNCTION operaciones.pedidos_listar(uuid,text,text,text,integer,date,date,boolean,timestamptz,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operaciones.pedidos_listar(uuid,text,text,text,integer,date,date,boolean,timestamptz,uuid) TO mastererp_app;
