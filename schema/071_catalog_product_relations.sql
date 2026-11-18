-- Canonical product-to-brand and product-to-supplier relations.
CREATE OR REPLACE FUNCTION catalogo.producto_relaciones_leer(p_producto uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); result jsonb;
BEGIN
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.products.read') IS NOT TRUE THEN
  RAISE EXCEPTION 'Product access denied' USING ERRCODE='42501'; END IF;
 SELECT jsonb_build_object('brand_ref',p.marca_ref,'suppliers',COALESCE((
  SELECT jsonb_agg(jsonb_build_object('id',x.tercero_id,'supplier_code',x.codigo_proveedor,
   'cost',x.costo,'lead_days',x.plazo_dias,'preferred',x.preferido) ORDER BY x.preferido DESC,s.codigo,x.tercero_id)
  FROM catalogo.producto_proveedores x JOIN catalogo.proveedores_catalogo s
   ON(s.tenant_id,s.tercero_id)=(x.tenant_id,x.tercero_id)
  WHERE x.tenant_id=tenant AND x.producto_id=p.id),'[]'::jsonb)) INTO result
 FROM catalogo.productos p WHERE p.tenant_id=tenant AND p.id=p_producto;
 IF result IS NULL THEN RAISE EXCEPTION 'Product not found' USING ERRCODE='P0002'; END IF;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION catalogo.producto_relaciones_actualizar(
 p_producto uuid,p_version bigint,p_marca text,p_proveedores jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id();actor uuid:=plataforma.current_app_user_id();
 current_version bigint; item record; preferred_count integer; correlation uuid;
BEGIN
 IF p_producto IS NULL OR p_version IS NULL OR jsonb_typeof(COALESCE(p_proveedores,'[]'))<>'array'
  OR jsonb_array_length(COALESCE(p_proveedores,'[]'))>50 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.products.write') IS NOT TRUE
  OR NULLIF(current_setting('app.current_operation',true),'') NOT IN ('catalog.products.create','catalog.products.update')
  THEN RAISE EXCEPTION 'Product relation update denied' USING ERRCODE='42501'; END IF;
 SELECT version INTO current_version FROM catalogo.productos WHERE tenant_id=tenant AND id=p_producto FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Product not found' USING ERRCODE='P0002'; END IF;
 IF current_version<>p_version THEN RAISE EXCEPTION 'Stale product version' USING ERRCODE='40001'; END IF;
 IF p_marca IS NOT NULL AND NOT EXISTS(SELECT 1 FROM catalogo.marcas WHERE tenant_id=tenant AND slug=p_marca)
  THEN RAISE EXCEPTION 'Brand not found' USING ERRCODE='23503'; END IF;
 SELECT count(*) INTO preferred_count FROM jsonb_to_recordset(COALESCE(p_proveedores,'[]'))
  AS x(id uuid,supplier_code text,cost numeric,lead_days integer,preferred boolean) WHERE COALESCE(preferred,false);
 IF preferred_count>1 THEN RAISE EXCEPTION 'Only one preferred supplier is allowed' USING ERRCODE='22023'; END IF;
 DELETE FROM catalogo.producto_proveedores WHERE tenant_id=tenant AND producto_id=p_producto;
 FOR item IN SELECT * FROM jsonb_to_recordset(COALESCE(p_proveedores,'[]'))
  AS x(id uuid,supplier_code text,cost numeric,lead_days integer,preferred boolean)
 LOOP
  IF item.id IS NULL OR item.cost IS NOT NULL AND item.cost<0 OR item.lead_days IS NOT NULL AND item.lead_days NOT BETWEEN 0 AND 3650
   OR NOT EXISTS(SELECT 1 FROM catalogo.proveedores_catalogo WHERE tenant_id=tenant AND tercero_id=item.id)
   THEN RAISE EXCEPTION 'Invalid supplier relation' USING ERRCODE='22023'; END IF;
  INSERT INTO catalogo.producto_proveedores(tenant_id,producto_id,tercero_id,codigo_proveedor,costo,plazo_dias,preferido)
  VALUES(tenant,p_producto,item.id,NULLIF(btrim(item.supplier_code),''),item.cost,item.lead_days,COALESCE(item.preferred,false));
 END LOOP;
 UPDATE catalogo.productos SET marca_ref=NULLIF(btrim(p_marca),''),version=version+1,actualizado_en=transaction_timestamp()
 WHERE tenant_id=tenant AND id=p_producto;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.3.4-products','producto',p_producto,'catalog.products.relations.update',correlation,
  jsonb_build_object('brand_ref',p_marca,'supplier_count',jsonb_array_length(COALESCE(p_proveedores,'[]'))));
 RETURN catalogo.producto_relaciones_leer(p_producto)||jsonb_build_object('version',current_version+1);
END $$;

REVOKE ALL ON FUNCTION catalogo.producto_relaciones_leer(uuid),catalogo.producto_relaciones_actualizar(uuid,bigint,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION catalogo.producto_relaciones_leer(uuid),catalogo.producto_relaciones_actualizar(uuid,bigint,text,jsonb) TO mastererp_app;
