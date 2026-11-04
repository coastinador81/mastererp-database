-- Preserve zero-stock inventory records without inventing a zero-quantity movement.
CREATE OR REPLACE FUNCTION catalogo.inventario_establecer(p_empresa uuid,p_nodo uuid,p_producto uuid,p_cantidad numeric,p_version bigint,p_motivo text,p_idempotency_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id(); correlation uuid;
 current catalogo.inventarios%ROWTYPE; fingerprint text; cached plataforma.idempotency_keys%ROWTYPE; response jsonb; previous numeric;
BEGIN
 IF p_cantidad<0 OR scale(p_cantidad)>6 OR length(btrim(p_motivo)) NOT BETWEEN 1 AND 500 OR length(p_idempotency_key) NOT BETWEEN 1 AND 128 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.inventory.write',p_empresa,p_nodo) IS NOT TRUE THEN RAISE EXCEPTION 'Inventory write denied' USING ERRCODE='42501'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'catalog.inventory.set' THEN RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 fingerprint:=encode(public.digest(jsonb_build_object('company',p_empresa,'node',p_nodo,'product',p_producto,'quantity',p_cantidad,'version',p_version,'reason',btrim(p_motivo))::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
 SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF cached.actor_user_id<>actor OR cached.request_tenant_id<>tenant OR cached.operation<>'catalog.inventory.set' OR cached.request_fingerprint<>fingerprint THEN RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505'; END IF;
  RETURN cached.response_payload;
 END IF;
 SELECT * INTO current FROM catalogo.inventarios WHERE tenant_id=tenant AND empresa_id=p_empresa AND nodo_id=p_nodo AND producto_id=p_producto FOR UPDATE;
 IF NOT FOUND THEN
  IF p_version IS NOT NULL AND p_version<>0 THEN RAISE EXCEPTION 'Stale inventory version' USING ERRCODE='40001'; END IF;
  previous:=0;
  INSERT INTO catalogo.inventarios(tenant_id,empresa_id,nodo_id,producto_id,existencia,actualizado_por) VALUES(tenant,p_empresa,p_nodo,p_producto,p_cantidad,actor);
 ELSE
  IF p_version IS NULL OR current.version<>p_version THEN RAISE EXCEPTION 'Stale inventory version' USING ERRCODE='40001'; END IF;
  IF p_cantidad<current.reservado THEN RAISE EXCEPTION 'Stock below reservations' USING ERRCODE='23514'; END IF;
  previous:=current.existencia;
  UPDATE catalogo.inventarios SET existencia=p_cantidad,version=version+1,actualizado_por=actor,actualizado_en=transaction_timestamp()
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND nodo_id=p_nodo AND producto_id=p_producto;
 END IF;
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(p_idempotency_key,actor,'catalog.inventory.set',p_producto,fingerprint,tenant);
 IF p_cantidad<>previous THEN
  INSERT INTO catalogo.movimientos_inventario(tenant_id,empresa_id,nodo_id,producto_id,tipo,cantidad,anterior,nuevo,motivo,actor_id,correlation_id)
  VALUES(tenant,p_empresa,p_nodo,p_producto,'SET',p_cantidad-previous,previous,p_cantidad,btrim(p_motivo),actor,correlation);
 END IF;
 response:=catalogo.inventario_leer(p_empresa,p_nodo,p_producto);
 UPDATE plataforma.idempotency_keys SET response_payload=response WHERE idempotency_key=p_idempotency_key;
 RETURN response;
END $$;

