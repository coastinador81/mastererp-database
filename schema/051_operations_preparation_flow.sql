-- Preparation owns CONFIRMED -> PREPARING -> READY; routes own OUT_FOR_DELIVERY/DELIVERED.
-- The generic order transition only confirms or cancels before preparation starts.
CREATE OR REPLACE FUNCTION operaciones.pedido_transicionar(
 p_empresa uuid,p_id uuid,p_version bigint,p_estado text,p_motivo text,p_detalle text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id();
 current operaciones.pedidos%ROWTYPE; operation text; correlation uuid; allowed boolean:=false;
BEGIN
 IF p_empresa IS NULL OR p_id IS NULL OR p_version IS NULL OR p_estado IS NULL
 OR p_motivo IS NULL OR length(btrim(p_motivo)) NOT BETWEEN 1 AND 80
 OR p_detalle IS NOT NULL AND length(p_detalle)>500 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.orders.write',p_empresa) IS NOT TRUE THEN
  RAISE EXCEPTION 'Order transition denied' USING ERRCODE='42501'; END IF;
 operation:='operations.orders.transition';
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM operation THEN
  RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL THEN RAISE EXCEPTION 'Correlation required' USING ERRCODE='22023'; END IF;
 SELECT * INTO current FROM operaciones.pedidos WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 IF current.version<>p_version THEN RAISE EXCEPTION 'Stale order version' USING ERRCODE='40001'; END IF;
 IF current.estado=p_estado THEN RETURN operaciones.pedidos_leer(p_empresa,p_id); END IF;
 allowed:=(current.estado,p_estado) IN (('PENDING','CONFIRMED'),('PENDING','CANCELLED'),('CONFIRMED','CANCELLED'));
 IF NOT allowed THEN RAISE EXCEPTION 'Invalid order transition' USING ERRCODE='23514'; END IF;
 IF current.estado='PENDING' AND p_estado='CONFIRMED' AND NOT (
  current.pago_snapshot->>'method' IN ('cash','pos') AND current.pago_snapshot->>'status'='PENDING_COLLECTION'
  OR current.pago_snapshot->>'method' IN ('mobile_payment','bank_transfer','custom') AND current.pago_snapshot->>'status'='VALIDATED')
 THEN RAISE EXCEPTION 'Payment not ready' USING ERRCODE='23514'; END IF;
 UPDATE operaciones.pedidos SET estado=p_estado,version=version+1,actualizado_en=transaction_timestamp() WHERE id=p_id;
 INSERT INTO operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,estado_anterior,estado_nuevo,motivo,detalle,actor_id,correlation_id)
 VALUES(tenant,p_empresa,p_id,current.estado,p_estado,btrim(p_motivo),NULLIF(btrim(p_detalle),''),actor,correlation);
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.3.1-orders','pedido',p_id,'operations.orders.transition',correlation,
  jsonb_build_object('empresa_id',p_empresa,'estado_anterior',current.estado,'estado_nuevo',p_estado,'resultado','succeeded'));
 RETURN operaciones.pedidos_leer(p_empresa,p_id);
END $$;

-- Orders moved to PREPARING by the former generic transition have no checklist;
-- starting preparation on them creates it without changing the order state again.
CREATE OR REPLACE FUNCTION operaciones.preparacion_iniciar(p_empresa uuid,p_pedido uuid,p_nodo uuid,p_version bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 current operaciones.pedidos%ROWTYPE; corr uuid; orphan boolean;
BEGIN
 IF plataforma.has_current_tenant_capability('erp.operations','operations.preparation.write',p_empresa,p_nodo) IS NOT TRUE
 OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'operations.preparation.start'
 THEN RAISE EXCEPTION 'Preparation start denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO current FROM operaciones.pedidos WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 IF current.version<>p_version THEN RAISE EXCEPTION 'Stale order version' USING ERRCODE='40001'; END IF;
 orphan:=current.estado='PREPARING' AND NOT EXISTS(SELECT 1 FROM operaciones.preparaciones
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND pedido_id=p_pedido);
 IF current.estado<>'CONFIRMED' AND NOT orphan THEN RAISE EXCEPTION 'Order not confirmed' USING ERRCODE='23514'; END IF;
 INSERT INTO operaciones.preparaciones VALUES(tenant,p_empresa,p_pedido,p_nodo,'IN_PROGRESS',actor,transaction_timestamp(),NULL,1);
 INSERT INTO operaciones.preparacion_lineas(tenant_id,empresa_id,pedido_id,linea_id)
 SELECT tenant,p_empresa,p_pedido,id FROM operaciones.pedido_lineas WHERE tenant_id=tenant AND empresa_id=p_empresa AND pedido_id=p_pedido;
 IF NOT orphan THEN
  UPDATE operaciones.pedidos SET estado='PREPARING',version=version+1,actualizado_en=transaction_timestamp() WHERE id=p_pedido;
  corr:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
  INSERT INTO operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,estado_anterior,estado_nuevo,motivo,actor_id,correlation_id)
  VALUES(tenant,p_empresa,p_pedido,'CONFIRMED','PREPARING','PREPARATION_STARTED',actor,corr);
 END IF;
 RETURN operaciones.preparacion_leer(p_empresa,p_pedido);
END $$;
