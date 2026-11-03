-- Controlled identity resolution for migration/integration consumers.
CREATE OR REPLACE FUNCTION catalogo.producto_id_por_referencia_externa(p_referencia text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,pg_temp AS $$
DECLARE result uuid;
BEGIN
 IF length(btrim(COALESCE(p_referencia,''))) NOT BETWEEN 1 AND 200 THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023';
 END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.products.read') IS NOT TRUE THEN
  RAISE EXCEPTION 'Product access denied' USING ERRCODE='42501';
 END IF;
 SELECT id INTO result FROM catalogo.productos
 WHERE tenant_id=plataforma.current_app_tenant_id()
 AND referencia_externa=btrim(p_referencia);
 IF result IS NULL THEN RAISE EXCEPTION 'Product not found' USING ERRCODE='P0002'; END IF;
 RETURN result;
END $$;

REVOKE ALL ON FUNCTION catalogo.producto_id_por_referencia_externa(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION catalogo.producto_id_por_referencia_externa(text) TO mastererp_app;
