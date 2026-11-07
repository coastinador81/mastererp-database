-- Read-only sales projection. No backfill, new business writes or role grants.
CREATE INDEX IF NOT EXISTS documentos_ventas_creacion_idx
 ON administracion.documentos(tenant_id,empresa_id,creado_en DESC,id DESC) WHERE clase='venta';
CREATE OR REPLACE FUNCTION administracion.ventas_leer(
 p_empresa uuid,p_id uuid DEFAULT NULL,p_limit integer DEFAULT 25,p_after uuid DEFAULT NULL,p_busqueda text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,administracion,operaciones,catalogo,plataforma,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); result jsonb; cursor_date timestamptz;
BEGIN
 IF plataforma.has_current_tenant_capability('erp.finance','administration.read',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Sales read denied' USING ERRCODE='42501'; END IF;
 IF p_empresa IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 101
 OR length(COALESCE(p_busqueda,''))>120 OR (p_id IS NOT NULL AND p_after IS NOT NULL)
 THEN RAISE EXCEPTION 'Invalid sales query' USING ERRCODE='22023'; END IF;
 IF p_after IS NOT NULL THEN
  SELECT d.creado_en INTO cursor_date FROM administracion.documentos d
  JOIN administracion.ventas_origen v ON (v.tenant_id,v.empresa_id,v.venta_id)=(d.tenant_id,d.empresa_id,d.id)
  WHERE d.tenant_id=tenant AND d.empresa_id=p_empresa AND d.id=p_after
  AND plataforma.has_current_tenant_capability('erp.finance','administration.read',p_empresa,d.sucursal_id);
  IF NOT FOUND THEN RAISE EXCEPTION 'Invalid sales cursor' USING ERRCODE='22023'; END IF;
 END IF;
 SELECT COALESCE(jsonb_agg(q.item ORDER BY q.created_at DESC,q.id DESC),'[]'::jsonb) INTO result
 FROM (
  SELECT d.id,d.creado_en created_at,jsonb_build_object(
   'id',d.id,'numero',d.numero,'fecha',d.fecha,'creado_en',d.creado_en,
   'estado',v.estado,'origen',v.origen_sistema,'version',v.version,
   'cliente',jsonb_build_object('id',d.tercero_id,'codigo',t.codigo,
     'nombre',COALESCE(NULLIF(v.cliente_snapshot->>'name',''),t.nombre)),
   'pedido',jsonb_build_object('id',p.id,'numero',p.numero),
   'moneda',d.moneda,'decimales',m.decimales,'total',d.total::text,
   'moneda_base',d.moneda_base,'decimales_base',mb.decimales,'total_base',d.total_base::text,
   'tipo_cambio',d.tipo_cambio::text,'cambio_fecha',d.cambio_fecha,'cambio_fuente',d.cambio_fuente
  ) || CASE WHEN p_id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('lineas',(
    SELECT COALESCE(jsonb_agg(jsonb_build_object('posicion',l.posicion,'producto_id',l.producto_id,
     'descripcion',l.descripcion,'cantidad',l.cantidad::text,'precio_unitario',l.precio_unitario::text,
     'subtotal',l.subtotal::text,'descuento',l.descuento::text,'recargo',l.recargo::text,
     'tributos',l.tributos::text,'total',l.total::text) ORDER BY l.posicion),'[]'::jsonb)
    FROM administracion.detalles_documento l
    WHERE l.tenant_id=tenant AND l.empresa_id=p_empresa AND l.documento_id=d.id)) END item
  FROM administracion.documentos d
  JOIN administracion.ventas_origen v ON (v.tenant_id,v.empresa_id,v.venta_id)=(d.tenant_id,d.empresa_id,d.id)
  JOIN operaciones.pedidos p ON (p.tenant_id,p.empresa_id,p.id)=(v.tenant_id,v.empresa_id,v.pedido_id)
  JOIN catalogo.terceros t ON (t.tenant_id,t.id)=(d.tenant_id,d.tercero_id)
  JOIN catalogo.monedas m ON m.codigo=d.moneda
  JOIN catalogo.monedas mb ON mb.codigo=d.moneda_base
  WHERE d.tenant_id=tenant AND d.empresa_id=p_empresa AND d.clase='venta'
  AND plataforma.has_current_tenant_capability('erp.finance','administration.read',p_empresa,d.sucursal_id)
  AND (p_id IS NULL OR d.id=p_id)
  AND (p_after IS NULL OR (d.creado_en,d.id)<(cursor_date,p_after))
  AND (NULLIF(btrim(p_busqueda),'') IS NULL OR position(lower(btrim(p_busqueda)) IN
       lower(COALESCE(d.numero,'')||' '||COALESCE(v.cliente_snapshot->>'name',t.nombre)||' '||p.numero))>0)
  ORDER BY d.creado_en DESC,d.id DESC LIMIT p_limit
 ) q;
 IF p_id IS NOT NULL THEN
  IF jsonb_array_length(result)=0 THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE='P0002'; END IF;
  RETURN result->0;
 END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION administracion.ventas_leer(uuid,uuid,integer,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION administracion.ventas_leer(uuid,uuid,integer,uuid,text) TO mastererp_app;

-- Preserve existing company readers and include the approved Finance read role.
CREATE OR REPLACE FUNCTION plataforma.current_frontend_context()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,plataforma,organizacion,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM plataforma.list_current_user_spaces()
               WHERE tenant_id=plataforma.current_app_tenant_id()) THEN
  RAISE EXCEPTION 'Context denied' USING ERRCODE='42501';
 END IF;
 SELECT jsonb_build_object(
  'tenant_id',plataforma.current_app_tenant_id(),
  'modules',COALESCE((SELECT jsonb_agg(m.code ORDER BY m.code)
   FROM plataforma.tenant_modules tm JOIN plataforma.modules m ON m.id=tm.module_id
   WHERE tm.tenant_id=plataforma.current_app_tenant_id() AND tm.status='active'
    AND m.status='active' AND (tm.expires_at IS NULL OR tm.expires_at>now())),'[]'::jsonb),
  'permissions',COALESCE((SELECT jsonb_agg(p.code ORDER BY p.code) FROM plataforma.permissions p
   WHERE plataforma.has_current_tenant_permission(p.code)),'[]'::jsonb),
  'companies',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',c.id,'name',c.legal_name) ORDER BY c.legal_name,c.id)
   FROM organizacion.companies c WHERE c.tenant_id=plataforma.current_app_tenant_id() AND c.status='active'
    AND (plataforma.has_current_tenant_capability('erp.finance','administration.parties.read',c.id) OR plataforma.has_current_tenant_capability('erp.finance','administration.purchases.read',c.id) OR plataforma.has_current_tenant_capability('erp.finance','administration.read',c.id))),'[]'::jsonb)
 ) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION plataforma.current_frontend_context() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION plataforma.current_frontend_context() TO mastererp_app;
