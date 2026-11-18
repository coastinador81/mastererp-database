-- Make Catalog products selectable in Inventory before their first stock record.
CREATE OR REPLACE FUNCTION catalogo.inventario_leer(p_empresa uuid,p_nodo uuid,p_producto uuid DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_empresa IS NULL OR p_nodo IS NULL OR p_limit NOT BETWEEN 1 AND 201 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023';END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.inventory.read',p_empresa,p_nodo) IS NOT TRUE THEN RAISE EXCEPTION 'Inventory access denied' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT 1 FROM operaciones.nodos n WHERE n.tenant_id=plataforma.current_app_tenant_id() AND n.empresa_id=p_empresa AND n.id=p_nodo) THEN RAISE EXCEPTION 'Node not found' USING ERRCODE='P0002';END IF;
 SELECT COALESCE(jsonb_agg(item ORDER BY nombre,id),'[]') INTO result FROM(SELECT p.nombre,p.id,jsonb_build_object(
  'company_id',p_empresa,'node_id',p_nodo,'product_id',p.id,'product_code',p.codigo,'product_name',p.nombre,
  'stock',COALESCE(i.existencia,0),'reserved',COALESCE(i.reservado,0),'available',COALESCE(i.disponible,0),
  'sales_enabled',COALESCE(i.ventas_habilitadas,true),'initialized',i.producto_id IS NOT NULL,
  'updated_at',i.actualizado_en,'version',COALESCE(i.version,0))item
 FROM catalogo.productos p LEFT JOIN catalogo.inventarios i ON i.tenant_id=p.tenant_id AND i.producto_id=p.id AND i.empresa_id=p_empresa AND i.nodo_id=p_nodo
 WHERE p.tenant_id=plataforma.current_app_tenant_id() AND p.estado<>'DISCONTINUED' AND(p_producto IS NULL OR p.id=p_producto)
 ORDER BY p.nombre,p.id LIMIT p_limit)q;
 IF p_producto IS NOT NULL AND jsonb_array_length(result)=0 THEN RAISE EXCEPTION 'Product not found' USING ERRCODE='P0002';END IF;
 RETURN CASE WHEN p_producto IS NULL THEN result ELSE result->0 END;
END $$;

REVOKE ALL ON FUNCTION catalogo.inventario_leer(uuid,uuid,uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION catalogo.inventario_leer(uuid,uuid,uuid,integer) TO mastererp_app;
