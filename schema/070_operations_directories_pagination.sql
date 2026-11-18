-- Complete, tenant-scoped directories for Preparation and Routes.
CREATE OR REPLACE FUNCTION operaciones.preparacion_directorio_leer(
 p_empresa uuid,p_estado text DEFAULT NULL,p_query text DEFAULT NULL,
 p_limit integer DEFAULT 50,p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); total bigint; items jsonb;
BEGIN
 IF p_limit NOT BETWEEN 1 AND 100 OR p_offset<0 OR length(COALESCE(p_query,''))>120 THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.preparation.read',p_empresa) IS NOT TRUE THEN
  RAISE EXCEPTION 'Preparation access denied' USING ERRCODE='42501'; END IF;
 SELECT count(*) INTO total FROM operaciones.preparaciones prep
 JOIN operaciones.pedidos ord ON (ord.tenant_id,ord.empresa_id,ord.id)=(prep.tenant_id,prep.empresa_id,prep.pedido_id)
 WHERE prep.tenant_id=tenant AND prep.empresa_id=p_empresa
  AND (p_estado IS NULL OR prep.estado=p_estado)
  AND (NULLIF(btrim(p_query),'') IS NULL OR ord.numero ILIKE '%'||btrim(p_query)||'%'
   OR COALESCE(ord.cliente_snapshot->>'name','') ILIKE '%'||btrim(p_query)||'%');
 SELECT COALESCE(jsonb_agg(operaciones.preparacion_leer(p_empresa,q.pedido_id) ORDER BY q.iniciado_en DESC,q.pedido_id),'[]')
 INTO items FROM (SELECT prep.pedido_id,prep.iniciado_en FROM operaciones.preparaciones prep
 JOIN operaciones.pedidos ord ON (ord.tenant_id,ord.empresa_id,ord.id)=(prep.tenant_id,prep.empresa_id,prep.pedido_id)
 WHERE prep.tenant_id=tenant AND prep.empresa_id=p_empresa
  AND (p_estado IS NULL OR prep.estado=p_estado)
  AND (NULLIF(btrim(p_query),'') IS NULL OR ord.numero ILIKE '%'||btrim(p_query)||'%'
   OR COALESCE(ord.cliente_snapshot->>'name','') ILIKE '%'||btrim(p_query)||'%')
 ORDER BY prep.iniciado_en DESC,prep.pedido_id LIMIT p_limit OFFSET p_offset)q;
 RETURN jsonb_build_object('items',items,'total',total,'next_offset',
  CASE WHEN p_offset+jsonb_array_length(items)<total THEN p_offset+jsonb_array_length(items) END);
END $$;

CREATE OR REPLACE FUNCTION operaciones.rutas_directorio_leer(
 p_empresa uuid,p_estado text DEFAULT NULL,p_query text DEFAULT NULL,
 p_limit integer DEFAULT 50,p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); total bigint; items jsonb;
BEGIN
 IF p_limit NOT BETWEEN 1 AND 100 OR p_offset<0 OR length(COALESCE(p_query,''))>120 THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.routes.read',p_empresa) IS NOT TRUE THEN
  RAISE EXCEPTION 'Route access denied' USING ERRCODE='42501'; END IF;
 SELECT count(*) INTO total FROM operaciones.rutas route WHERE route.tenant_id=tenant AND route.empresa_id=p_empresa
  AND (p_estado IS NULL OR route.estado=p_estado)
  AND (NULLIF(btrim(p_query),'') IS NULL OR route.id::text ILIKE '%'||btrim(p_query)||'%'
   OR EXISTS(SELECT 1 FROM operaciones.ruta_paradas stop JOIN operaciones.pedidos ord
    ON (ord.tenant_id,ord.empresa_id,ord.id)=(stop.tenant_id,stop.empresa_id,stop.pedido_id)
    WHERE (stop.tenant_id,stop.empresa_id,stop.ruta_id)=(route.tenant_id,route.empresa_id,route.id)
     AND (ord.numero ILIKE '%'||btrim(p_query)||'%' OR COALESCE(ord.cliente_snapshot->>'name','') ILIKE '%'||btrim(p_query)||'%')));
 SELECT COALESCE(jsonb_agg(operaciones.ruta_respuesta(tenant,p_empresa,q.id) ORDER BY q.fecha DESC,q.creado_en DESC,q.id),'[]')
 INTO items FROM (SELECT route.id,route.fecha,route.creado_en FROM operaciones.rutas route
 WHERE route.tenant_id=tenant AND route.empresa_id=p_empresa
  AND (p_estado IS NULL OR route.estado=p_estado)
  AND (NULLIF(btrim(p_query),'') IS NULL OR route.id::text ILIKE '%'||btrim(p_query)||'%'
   OR EXISTS(SELECT 1 FROM operaciones.ruta_paradas stop JOIN operaciones.pedidos ord
    ON (ord.tenant_id,ord.empresa_id,ord.id)=(stop.tenant_id,stop.empresa_id,stop.pedido_id)
    WHERE (stop.tenant_id,stop.empresa_id,stop.ruta_id)=(route.tenant_id,route.empresa_id,route.id)
     AND (ord.numero ILIKE '%'||btrim(p_query)||'%' OR COALESCE(ord.cliente_snapshot->>'name','') ILIKE '%'||btrim(p_query)||'%')))
 ORDER BY route.fecha DESC,route.creado_en DESC,route.id LIMIT p_limit OFFSET p_offset)q;
 RETURN jsonb_build_object('items',items,'total',total,'next_offset',
  CASE WHEN p_offset+jsonb_array_length(items)<total THEN p_offset+jsonb_array_length(items) END);
END $$;

REVOKE ALL ON FUNCTION operaciones.preparacion_directorio_leer(uuid,text,text,integer,integer),
 operaciones.rutas_directorio_leer(uuid,text,text,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operaciones.preparacion_directorio_leer(uuid,text,text,integer,integer),
 operaciones.rutas_directorio_leer(uuid,text,text,integer,integer) TO mastererp_app;
