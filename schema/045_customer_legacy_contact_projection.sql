-- Read-only compatibility projection for legacy Catalog phone. No data updates or backfill.
CREATE OR REPLACE FUNCTION administracion.parties_read_v2(
 p_company uuid,p_role text,p_id uuid DEFAULT NULL,p_limit integer DEFAULT 25,p_after uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,catalogo,plataforma,organizacion,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_company IS NULL OR p_role IS NULL OR p_role NOT IN ('cliente','proveedor')
 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 101 THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.finance','administration.parties.read',p_company) IS NOT TRUE THEN
  RAISE EXCEPTION 'Party access denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(item ORDER BY id),'[]') INTO result FROM (
 SELECT t.id,jsonb_build_object('id',t.id,'profile_id',p.id,'company_id',p.empresa_id,
  'codigo',t.codigo,'nombre',t.nombre,'version',t.version,'profile_version',p.version,
  'datos_generales',COALESCE((SELECT jsonb_object_agg(k,v) FROM jsonb_each(CASE WHEN COALESCE(t.datos_administrativos,s.contacto,'{}'::jsonb) ? 'telefono' THEN COALESCE(t.datos_administrativos,s.contacto,'{}'::jsonb) ELSE catalogo.normalizar_contacto_administrativo(COALESCE(t.datos_administrativos,s.contacto,'{}'::jsonb)) END) e(k,v) WHERE k IN ('nombre_comercial','tipo_persona','pais_fiscal','tipo_identificacion','numero_identificacion','direccion','direccion_complementaria','ciudad','municipio','region','codigo_postal','pais','email','telefono','telefono_alterno','sitio_web','observaciones')),'{}'::jsonb),
  'contactos',CASE WHEN jsonb_typeof(COALESCE(t.datos_administrativos,s.contacto)->'personas')='array' THEN COALESCE(t.datos_administrativos,s.contacto)->'personas' ELSE '[]'::jsonb END,'catalog_version',COALESCE(s.version,0),'catalog_status',s.estado,
  'condiciones',COALESCE(p.datos_comerciales,'{}'::jsonb)||jsonb_build_object(
    'plazo_pago_dias',COALESCE((SELECT c.dias_plazo::text FROM administracion.condiciones_comerciales c WHERE c.id=p.condicion_id AND c.tenant_id=p.tenant_id AND c.empresa_id=p.empresa_id),''),
    'descuento_pronto_pago',COALESCE((SELECT d.porcentaje::text FROM administracion.descuentos_pronto_pago d WHERE d.condicion_id=p.condicion_id AND d.tenant_id=p.tenant_id AND d.empresa_id=p.empresa_id LIMIT 1),''),
    'plazo_pronto_pago_dias',COALESCE((SELECT d.hasta_dias::text FROM administracion.descuentos_pronto_pago d WHERE d.condicion_id=p.condicion_id AND d.tenant_id=p.tenant_id AND d.empresa_id=p.empresa_id LIMIT 1),'')),
  'origen',CASE WHEN EXISTS(SELECT 1 FROM ventas_digitales.cliente_identidades ci WHERE ci.tenant_id=p.tenant_id AND ci.empresa_id=p.empresa_id AND ci.cliente_id=t.id) THEN 'ecommerce' ELSE 'sin_canal_identificado' END,
  'contacto_ecommerce',CASE WHEN p_role='cliente' THEN (SELECT jsonb_build_object('telefono',ec.telefono,'email',u.email) FROM ventas_digitales.cliente_identidades ci JOIN plataforma.users u ON u.id=ci.user_id LEFT JOIN ventas_digitales.cliente_perfiles ec ON (ec.tenant_id,ec.empresa_id,ec.cliente_id)=(ci.tenant_id,ci.empresa_id,ci.cliente_id) WHERE (ci.tenant_id,ci.empresa_id,ci.cliente_id)=(p.tenant_id,p.empresa_id,t.id)) ELSE NULL END,
  'roles',(SELECT jsonb_agg(x.rol ORDER BY x.rol) FROM administracion.perfiles_tercero x
   WHERE x.tenant_id=p.tenant_id AND x.empresa_id=p.empresa_id AND x.tercero_id=t.id)) item
 FROM catalogo.terceros t JOIN administracion.perfiles_tercero p
 ON (p.tenant_id,p.tercero_id)=(t.tenant_id,t.id)
 LEFT JOIN catalogo.proveedores_catalogo s ON (s.tenant_id,s.tercero_id)=(t.tenant_id,t.id)
 WHERE t.tenant_id=plataforma.current_app_tenant_id() AND p.empresa_id=p_company AND p.rol=p_role
 AND (p_id IS NULL OR t.id=p_id) AND (p_after IS NULL OR t.id>p_after)
 ORDER BY t.id LIMIT p_limit) q;
 IF p_id IS NOT NULL AND jsonb_array_length(result)=0 THEN
  RAISE EXCEPTION 'Party not found' USING ERRCODE='P0002'; END IF;
 RETURN CASE WHEN p_id IS NULL THEN result ELSE result->0 END;
END $$;
