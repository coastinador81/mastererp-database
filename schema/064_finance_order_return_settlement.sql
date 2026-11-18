-- Finance references must resolve to immutable records in the same tenant,
-- company, order and return case. Text supplied by a browser is never proof.
CREATE OR REPLACE FUNCTION operaciones.devolucion_completar(
 p_empresa uuid,p_devolucion uuid,p_version bigint,p_reembolso text,p_nota_credito text,p_detalle text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,administracion,plataforma,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 current operaciones.devoluciones_pedido%ROWTYPE; order_row operaciones.pedidos%ROWTYPE;
 refund_id uuid; credit_id uuid; correlation uuid;
BEGIN
 BEGIN refund_id:=p_reembolso::uuid; credit_id:=p_nota_credito::uuid;
 EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'Invalid financial references' USING ERRCODE='22023'; END;
 IF p_version<1 OR length(btrim(COALESCE(p_detalle,''))) NOT BETWEEN 3 AND 500
 THEN RAISE EXCEPTION 'Invalid return settlement' USING ERRCODE='22023'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'administration.returns.settle'
 OR plataforma.has_current_tenant_capability('erp.finance','administration.returns.settle',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Return settlement denied' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 SELECT * INTO current FROM operaciones.devoluciones_pedido
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_devolucion FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Return not found' USING ERRCODE='P0002'; END IF;
 IF current.version<>p_version THEN RAISE EXCEPTION 'Stale return version' USING ERRCODE='40001'; END IF;
 IF current.estado<>'RECEIVED' THEN RAISE EXCEPTION 'Received return required' USING ERRCODE='23514'; END IF;
 SELECT * INTO order_row FROM operaciones.pedidos
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=current.pedido_id;
 IF NOT EXISTS(SELECT 1 FROM administracion.operaciones_tesoreria r
  JOIN administracion.movimientos_tesoreria m ON (m.tenant_id,m.empresa_id,m.operacion_id)=(r.tenant_id,r.empresa_id,r.id)
  WHERE r.tenant_id=tenant AND r.empresa_id=p_empresa AND r.id=refund_id AND r.tipo='pago'
   AND r.tercero_id=order_row.cliente_id AND r.origen_sistema='order_return'
   AND r.referencia_externa=p_devolucion::text AND m.sentido='salida')
 THEN RAISE EXCEPTION 'Recorded refund required' USING ERRCODE='23514'; END IF;
 IF NOT EXISTS(SELECT 1 FROM administracion.documentos c
  JOIN administracion.documentos origin ON (origin.tenant_id,origin.empresa_id,origin.id)=
   (c.tenant_id,c.empresa_id,c.documento_origen_id)
  WHERE c.tenant_id=tenant AND c.empresa_id=p_empresa AND c.id=credit_id
   AND c.clase='credito_cliente' AND c.cerrado AND c.tercero_id=order_row.cliente_id
   AND c.origen_sistema='order_return' AND c.referencia_externa=p_devolucion::text
   AND origin.clase='factura_cliente' AND origin.referencia_externa=current.pedido_id::text)
 THEN RAISE EXCEPTION 'Sealed customer credit note required' USING ERRCODE='23514'; END IF;
 UPDATE operaciones.devoluciones_pedido SET estado='COMPLETED',referencia_reembolso=refund_id::text,
  referencia_nota_credito=credit_id::text,completado_por=actor,completado_en=transaction_timestamp(),
  version=version+1 WHERE id=p_devolucion;
 INSERT INTO operaciones.devolucion_pedido_eventos(tenant_id,empresa_id,devolucion_id,estado,detalle,actor_id,correlation_id)
 VALUES(tenant,p_empresa,p_devolucion,'COMPLETED',btrim(p_detalle),actor,correlation);
 RETURN operaciones.devoluciones_leer(p_empresa,current.pedido_id,p_devolucion);
END $$;
REVOKE ALL ON FUNCTION operaciones.devolucion_completar(uuid,uuid,bigint,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operaciones.devolucion_completar(uuid,uuid,bigint,text,text,text) TO mastererp_app;
