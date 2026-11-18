-- Cancellation matrix for pre-delivery stages. Goods in transit must return
-- through the route evidence flow before an administrative cancellation.
ALTER TABLE catalogo.movimientos_inventario
 DROP CONSTRAINT IF EXISTS movimientos_inventario_tipo_check;
ALTER TABLE catalogo.movimientos_inventario
 ADD CONSTRAINT movimientos_inventario_tipo_check
 CHECK(tipo IN ('SET','ADJUST','RESERVE','RELEASE','COMMIT','RETURN','RESTOCK'));
ALTER TABLE catalogo.reservas_inventario
 DROP CONSTRAINT IF EXISTS reservas_inventario_estado_check;
ALTER TABLE catalogo.reservas_inventario
 ADD CONSTRAINT reservas_inventario_estado_check
 CHECK(estado IN ('ACTIVE','RELEASED','COMMITTED','REVERSED'));

CREATE OR REPLACE FUNCTION catalogo.inventario_reserva_revertir(
 p_empresa uuid,p_reserva uuid,p_motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 correlation uuid; reservation catalogo.reservas_inventario%ROWTYPE; line record;
 current catalogo.inventarios%ROWTYPE;
BEGIN
 IF p_empresa IS NULL OR p_reserva IS NULL OR length(btrim(p_motivo)) NOT BETWEEN 1 AND 500
 THEN RAISE EXCEPTION 'Invalid inventory reversal' USING ERRCODE='22023'; END IF;
 SELECT * INTO reservation FROM catalogo.reservas_inventario
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_reserva FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found' USING ERRCODE='P0002'; END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.inventory.reserve',p_empresa,reservation.nodo_id) IS NOT TRUE
 OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'operations.orders.cancel.inventory'
 THEN RAISE EXCEPTION 'Inventory reversal denied' USING ERRCODE='42501'; END IF;
 IF reservation.estado='REVERSED' THEN
  RETURN jsonb_build_object('reservation_ref',p_reserva,'status','REVERSED');
 END IF;
 IF reservation.estado<>'COMMITTED' THEN
  RAISE EXCEPTION 'Committed reservation required' USING ERRCODE='23514'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL THEN RAISE EXCEPTION 'Correlation required' USING ERRCODE='22023'; END IF;
 FOR line IN SELECT * FROM catalogo.reserva_inventario_lineas
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND reserva_id=p_reserva ORDER BY producto_id
 LOOP
  SELECT * INTO current FROM catalogo.inventarios WHERE tenant_id=tenant AND empresa_id=p_empresa
   AND nodo_id=line.nodo_id AND producto_id=line.producto_id FOR UPDATE;
  UPDATE catalogo.inventarios SET existencia=existencia+line.cantidad,version=version+1,
   actualizado_por=actor,actualizado_en=transaction_timestamp()
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND nodo_id=line.nodo_id AND producto_id=line.producto_id;
  INSERT INTO catalogo.movimientos_inventario(tenant_id,empresa_id,nodo_id,producto_id,tipo,cantidad,
   anterior,nuevo,motivo,referencia,actor_id,correlation_id)
  VALUES(tenant,p_empresa,line.nodo_id,line.producto_id,'RESTOCK',line.cantidad,current.existencia,
   current.existencia+line.cantidad,btrim(p_motivo),p_reserva::text,actor,correlation);
 END LOOP;
 UPDATE catalogo.reservas_inventario SET estado='REVERSED',actualizado_en=transaction_timestamp()
 WHERE id=p_reserva;
 RETURN jsonb_build_object('reservation_ref',p_reserva,'status','REVERSED');
END $$;

CREATE OR REPLACE FUNCTION operaciones.pedido_cancelar(
 p_empresa uuid,p_pedido uuid,p_version bigint,p_motivo text,p_detalle text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,catalogo,administracion,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 current operaciones.pedidos%ROWTYPE; prep operaciones.preparaciones%ROWTYPE;
 reservation catalogo.reservas_inventario%ROWTYPE; sale administracion.ventas_origen%ROWTYPE;
 inventory_result jsonb; sale_result jsonb; correlation uuid;
BEGIN
 IF p_empresa IS NULL OR p_pedido IS NULL OR p_version IS NULL
 OR length(btrim(p_motivo)) NOT BETWEEN 1 AND 80 OR (p_detalle IS NOT NULL AND length(p_detalle)>500)
 THEN RAISE EXCEPTION 'Invalid cancellation' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.orders.write',p_empresa) IS NOT TRUE
 OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'operations.orders.cancel'
 THEN RAISE EXCEPTION 'Order cancellation denied' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL THEN RAISE EXCEPTION 'Correlation required' USING ERRCODE='22023'; END IF;
 SELECT * INTO current FROM operaciones.pedidos
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 IF current.estado='CANCELLED' THEN RETURN operaciones.pedidos_leer(p_empresa,p_pedido); END IF;
 IF current.version<>p_version THEN RAISE EXCEPTION 'Stale order version' USING ERRCODE='40001'; END IF;
 IF current.estado='OUT_FOR_DELIVERY' THEN
  RAISE EXCEPTION 'Close delivery as failed before cancellation' USING ERRCODE='23514'; END IF;
 IF current.estado NOT IN ('PENDING','CONFIRMED','PREPARING','READY') THEN
  RAISE EXCEPTION 'Order cannot be cancelled' USING ERRCODE='23514'; END IF;
 SELECT * INTO reservation FROM catalogo.reservas_inventario
 WHERE tenant_id=tenant AND empresa_id=p_empresa
 AND (id::text=current.reserva_inventario_ref OR referencia_externa=current.reserva_inventario_ref) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Inventory reservation not found' USING ERRCODE='P0002'; END IF;
 IF reservation.estado='ACTIVE' THEN
  PERFORM set_config('app.current_operation','catalog.inventory.reservation.finalize',true);
  inventory_result:=catalogo.inventario_reserva_finalizar(p_empresa,reservation.id,'RELEASE',btrim(p_motivo));
 ELSIF reservation.estado='COMMITTED' AND current.estado='READY' THEN
  PERFORM set_config('app.current_operation','operations.orders.cancel.inventory',true);
  inventory_result:=catalogo.inventario_reserva_revertir(p_empresa,reservation.id,btrim(p_motivo));
 ELSE
  RAISE EXCEPTION 'Inventory state prevents cancellation' USING ERRCODE='23514';
 END IF;
 SELECT * INTO prep FROM operaciones.preparaciones
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND pedido_id=p_pedido FOR UPDATE;
 IF FOUND THEN
  IF current.estado='PREPARING' AND prep.estado<>'IN_PROGRESS' OR current.estado='READY' AND prep.estado<>'COMPLETED'
  THEN RAISE EXCEPTION 'Preparation state prevents cancellation' USING ERRCODE='23514'; END IF;
  UPDATE operaciones.preparaciones SET estado='CANCELLED',version=version+1
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND pedido_id=p_pedido;
 END IF;
 UPDATE operaciones.pedidos SET estado='CANCELLED',ruta_ref=NULL,version=version+1,
  actualizado_en=transaction_timestamp() WHERE id=p_pedido;
 INSERT INTO operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,estado_anterior,estado_nuevo,
  motivo,detalle,actor_id,correlation_id)
 VALUES(tenant,p_empresa,p_pedido,current.estado,'CANCELLED',btrim(p_motivo),
  NULLIF(btrim(p_detalle),''),actor,correlation);
 SELECT * INTO sale FROM administracion.ventas_origen
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND pedido_id=p_pedido FOR UPDATE;
 IF FOUND THEN
  PERFORM set_config('app.current_operation','administracion.venta.anular',true);
  sale_result:=administracion.venta_anular(p_empresa,p_pedido,sale.version,btrim(p_motivo));
 END IF;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,
  correlation_id,metadata)
 VALUES(tenant,actor,'2.3.1-orders','pedido',p_pedido,'operations.orders.cancel',correlation,
  jsonb_build_object('empresa_id',p_empresa,'estado_anterior',current.estado,'resultado','succeeded'));
 PERFORM set_config('app.current_operation','operations.orders.cancel',true);
 RETURN operaciones.pedidos_leer(p_empresa,p_pedido)
  || jsonb_build_object('inventory',inventory_result,'sale',sale_result);
END $$;

REVOKE ALL ON FUNCTION catalogo.inventario_reserva_revertir(uuid,uuid,text),
 operaciones.pedido_cancelar(uuid,uuid,bigint,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION catalogo.inventario_reserva_revertir(uuid,uuid,text),
 operaciones.pedido_cancelar(uuid,uuid,bigint,text,text) TO mastererp_app;
