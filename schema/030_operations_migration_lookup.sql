CREATE OR REPLACE FUNCTION operaciones.pedido_id_por_referencia_externa(p_empresa uuid,p_referencia text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,pg_temp AS $$
DECLARE result uuid;
BEGIN
 IF p_empresa IS NULL OR length(btrim(COALESCE(p_referencia,''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.orders.read',p_empresa) IS NOT TRUE THEN RAISE EXCEPTION 'Order access denied' USING ERRCODE='42501'; END IF;
 SELECT id INTO result FROM operaciones.pedidos WHERE tenant_id=plataforma.current_app_tenant_id() AND empresa_id=p_empresa AND referencia_externa=btrim(p_referencia);
 IF result IS NULL THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION operaciones.pedido_id_por_referencia_externa(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operaciones.pedido_id_por_referencia_externa(uuid,text) TO mastererp_app;
