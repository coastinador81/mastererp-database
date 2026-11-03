-- Controlled customer identity resolution for migration/integration consumers.
CREATE OR REPLACE FUNCTION administracion.cliente_id_por_referencia_externa(
 p_company uuid,p_referencia text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,catalogo,plataforma,pg_temp AS $$
DECLARE result uuid;
BEGIN
 IF p_company IS NULL OR length(btrim(COALESCE(p_referencia,''))) NOT BETWEEN 1 AND 80 THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023';
 END IF;
 IF plataforma.has_current_tenant_capability(
  'erp.finance','administration.parties.read',p_company) IS NOT TRUE THEN
  RAISE EXCEPTION 'Party access denied' USING ERRCODE='42501';
 END IF;
 SELECT t.id INTO result
 FROM catalogo.terceros t
 JOIN administracion.perfiles_tercero p
 ON (p.tenant_id,p.tercero_id)=(t.tenant_id,t.id)
 WHERE t.tenant_id=plataforma.current_app_tenant_id()
 AND p.empresa_id=p_company AND p.rol='cliente'
 AND t.codigo=btrim(p_referencia);
 IF result IS NULL THEN RAISE EXCEPTION 'Customer not found' USING ERRCODE='P0002'; END IF;
 RETURN result;
END $$;

REVOKE ALL ON FUNCTION administracion.cliente_id_por_referencia_externa(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION administracion.cliente_id_por_referencia_externa(uuid,text) TO mastererp_app;
