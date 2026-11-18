-- Canonical settlement of a validated payment after order cancellation.
INSERT INTO plataforma.permissions(code,description) VALUES
 ('administration.order_refunds.write','Settle cancelled order refunds') ON CONFLICT(code) DO NOTHING;
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT id,'administration.order_refunds.write' FROM plataforma.roles
 WHERE code IN ('tenant.owner','tenant.finance_admin') ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS administracion.reembolsos_pedido (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,empresa_id uuid NOT NULL,
 pedido_id uuid NOT NULL,operacion_id uuid NOT NULL,movimiento_id uuid NOT NULL,nota_credito_id uuid NOT NULL,
 metodo text NOT NULL CHECK(length(btrim(metodo)) BETWEEN 1 AND 80),
 referencia text NOT NULL CHECK(length(btrim(referencia)) BETWEEN 1 AND 200),
 creado_por uuid NOT NULL REFERENCES plataforma.users(id),creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 idempotency_key varchar(128) NOT NULL UNIQUE REFERENCES plataforma.idempotency_keys(idempotency_key) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(tenant_id,empresa_id,pedido_id),UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,pedido_id) REFERENCES operaciones.pedidos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,operacion_id) REFERENCES administracion.operaciones_tesoreria(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,movimiento_id) REFERENCES administracion.movimientos_tesoreria(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,nota_credito_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id));
ALTER TABLE administracion.reembolsos_pedido ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.reembolsos_pedido FROM PUBLIC,mastererp_app;

CREATE OR REPLACE FUNCTION administracion.cuentas_reembolso_leer(p_empresa uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,plataforma,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF plataforma.has_current_tenant_capability('erp.finance','administration.order_refunds.write',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Refund accounts denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'code',codigo,'name',nombre,'type',tipo,'currency',moneda)
 ORDER BY tipo,nombre),'[]') INTO result FROM administracion.cuentas_tesoreria
 WHERE tenant_id=plataforma.current_app_tenant_id() AND empresa_id=p_empresa;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION administracion.notas_credito_reembolso_leer(p_empresa uuid,p_pedido uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,operaciones,plataforma,pg_temp AS $$
DECLARE result jsonb;customer uuid;currency char(3);amount numeric;
BEGIN
 IF plataforma.has_current_tenant_capability('erp.finance','administration.order_refunds.write',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Credit notes denied' USING ERRCODE='42501'; END IF;
 SELECT cliente_id,moneda,total INTO customer,currency,amount FROM operaciones.pedidos
 WHERE tenant_id=plataforma.current_app_tenant_id() AND empresa_id=p_empresa AND id=p_pedido;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'number',numero,'date',fecha,'currency',moneda,'total',total)
  ORDER BY fecha DESC,numero),'[]') INTO result FROM administracion.documentos
 WHERE tenant_id=plataforma.current_app_tenant_id() AND empresa_id=p_empresa AND clase='credito_cliente'
 AND cerrado AND tercero_id=customer AND moneda=currency AND total=amount AND referencia_externa=p_pedido::text
 AND NOT EXISTS(SELECT 1 FROM administracion.reembolsos_pedido r WHERE r.nota_credito_id=documentos.id);
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION administracion.reembolso_pedido_registrar(
 p_empresa uuid,p_pedido uuid,p_cuenta uuid,p_importe numeric,p_moneda char(3),p_fecha date,
 p_metodo text,p_referencia text,p_nota_credito uuid,p_idempotency_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,operaciones,plataforma,organizacion,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id();actor uuid:=plataforma.current_app_user_id();
 pedido operaciones.pedidos%ROWTYPE;venta administracion.ventas_origen%ROWTYPE;origen administracion.documentos%ROWTYPE;credito administracion.documentos%ROWTYPE;
 cuenta administracion.cuentas_tesoreria%ROWTYPE;cached plataforma.idempotency_keys%ROWTYPE;
 rid uuid:=gen_random_uuid();oid uuid:=gen_random_uuid();mid uuid:=gen_random_uuid();
 fingerprint text;correlation uuid;base char(3);response jsonb;treasury_key varchar(128);
BEGIN
 IF p_importe<=0 OR p_fecha IS NULL OR length(btrim(COALESCE(p_metodo,''))) NOT BETWEEN 1 AND 80
 OR length(btrim(COALESCE(p_referencia,''))) NOT BETWEEN 1 AND 200
 OR p_nota_credito IS NULL
 OR length(p_idempotency_key) NOT BETWEEN 1 AND 128 THEN RAISE EXCEPTION 'Invalid refund' USING ERRCODE='22023'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'administration.order_refunds.write'
 OR plataforma.has_current_tenant_capability('erp.finance','administration.order_refunds.write',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Refund denied' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
 fingerprint:=encode(public.digest(jsonb_build_object('company',p_empresa,'order',p_pedido,'account',p_cuenta,
  'amount',p_importe,'currency',p_moneda,'date',p_fecha,'method',btrim(p_metodo),'reference',btrim(p_referencia),
  'credit_note',p_nota_credito)::text,'sha256'),'hex');
 treasury_key:='refund-treasury:'||substr(encode(public.digest(p_idempotency_key,'sha256'),'hex'),1,64);
 SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF cached.actor_user_id<>actor OR cached.request_tenant_id<>tenant OR cached.operation<>'administration.order_refunds.write'
  OR cached.request_fingerprint<>fingerprint OR cached.response_payload IS NULL
  THEN RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505'; END IF;
  RETURN cached.response_payload;
 END IF;
 SELECT * INTO pedido FROM operaciones.pedidos WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 IF pedido.estado<>'CANCELLED' OR pedido.pago_snapshot->>'status'<>'VALIDATED'
 THEN RAISE EXCEPTION 'Cancelled validated order required' USING ERRCODE='23514'; END IF;
 IF p_importe<>pedido.total OR p_moneda<>pedido.moneda THEN RAISE EXCEPTION 'Full refund required' USING ERRCODE='23514'; END IF;
 SELECT * INTO cuenta FROM administracion.cuentas_tesoreria WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_cuenta FOR UPDATE;
 IF NOT FOUND OR cuenta.moneda<>p_moneda THEN RAISE EXCEPTION 'Matching treasury account required' USING ERRCODE='23514'; END IF;
 SELECT * INTO venta FROM administracion.ventas_origen WHERE tenant_id=tenant AND empresa_id=p_empresa AND pedido_id=p_pedido FOR UPDATE;
 IF NOT FOUND OR venta.estado<>'CANCELLED' THEN RAISE EXCEPTION 'Cancelled sale required' USING ERRCODE='23514'; END IF;
 SELECT * INTO origen FROM administracion.documentos WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=venta.venta_id;
 SELECT * INTO credito FROM administracion.documentos WHERE tenant_id=tenant AND empresa_id=p_empresa
  AND id=p_nota_credito AND clase='credito_cliente' AND cerrado AND tercero_id=pedido.cliente_id
  AND moneda=pedido.moneda AND total=pedido.total AND referencia_externa=p_pedido::text;
 IF NOT FOUND THEN RAISE EXCEPTION 'Compatible sealed credit note required' USING ERRCODE='23514'; END IF;
 SELECT base_currency_code INTO base FROM organizacion.companies WHERE tenant_id=tenant AND id=p_empresa AND status='active';
 IF EXISTS(SELECT 1 FROM administracion.reembolsos_pedido WHERE tenant_id=tenant AND empresa_id=p_empresa AND pedido_id=p_pedido)
 THEN RAISE EXCEPTION 'Order already refunded' USING ERRCODE='23505'; END IF;
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(p_idempotency_key,actor,'administration.order_refunds.write',rid,fingerprint,tenant);
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(treasury_key,actor,'administracion.tesoreria.crear',oid,fingerprint,tenant);
 INSERT INTO administracion.operaciones_tesoreria(id,tenant_id,empresa_id,sucursal_id,tipo,tercero_id,fecha,idempotency_key,origen_sistema,referencia_externa,creado_por)
 VALUES(oid,tenant,p_empresa,pedido.sucursal_id,'pago',pedido.cliente_id,p_fecha,treasury_key,'order_cancellation',p_pedido::text,actor);
 INSERT INTO administracion.movimientos_tesoreria(id,tenant_id,empresa_id,sucursal_id,operacion_id,cuenta_id,sentido,moneda,importe,moneda_base,tipo_cambio,cambio_fecha,cambio_fuente,creado_por)
 VALUES(mid,tenant,p_empresa,pedido.sucursal_id,oid,p_cuenta,'salida',p_moneda,p_importe,base,origen.tipo_cambio,origen.cambio_fecha,origen.cambio_fuente,actor);
 INSERT INTO administracion.reembolsos_pedido(id,tenant_id,empresa_id,pedido_id,operacion_id,movimiento_id,nota_credito_id,metodo,referencia,creado_por,idempotency_key)
 VALUES(rid,tenant,p_empresa,p_pedido,oid,mid,credito.id,btrim(p_metodo),btrim(p_referencia),actor,p_idempotency_key);
 UPDATE operaciones.pedidos SET pago_snapshot=pago_snapshot||jsonb_build_object('status','REFUNDED','refund_id',rid,
  'refunded_at',transaction_timestamp(),'refund_reference',btrim(p_referencia),'credit_note_number',credito.numero),
  version=version+1,actualizado_en=transaction_timestamp() WHERE id=p_pedido;
 response:=jsonb_build_object('id',rid,'order_id',p_pedido,'status','REFUNDED','operation_id',oid,'movement_id',mid,
  'credit_note_id',credito.id,'credit_note_number',credito.numero,'method',btrim(p_metodo),'reference',btrim(p_referencia),
  'amount',p_importe,'currency',p_moneda,'date',p_fecha,'recorded_at',transaction_timestamp());
 UPDATE plataforma.idempotency_keys SET response_payload=response WHERE idempotency_key=p_idempotency_key;
 INSERT INTO operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,estado_anterior,estado_nuevo,motivo,detalle,actor_id,correlation_id)
 VALUES(tenant,p_empresa,p_pedido,'CANCELLED','CANCELLED','ORDER_REFUNDED','Reembolso '||btrim(p_referencia)||' · Nota de crédito '||credito.numero,actor,correlation);
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.2.1.4.1-cobros','reembolso_pedido',rid,'administration.order_refunds.write',correlation,
 jsonb_build_object('empresa_id',p_empresa,'pedido_id',p_pedido,'resultado','succeeded'));
 RETURN response;
END $$;

REVOKE ALL ON FUNCTION administracion.cuentas_reembolso_leer(uuid),administracion.notas_credito_reembolso_leer(uuid,uuid),administracion.reembolso_pedido_registrar(uuid,uuid,uuid,numeric,char,date,text,text,uuid,varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION administracion.cuentas_reembolso_leer(uuid),administracion.notas_credito_reembolso_leer(uuid,uuid),administracion.reembolso_pedido_registrar(uuid,uuid,uuid,numeric,char,date,text,text,uuid,varchar) TO mastererp_app;

CREATE OR REPLACE FUNCTION administracion.pagos_pendientes_leer(p_empresa uuid,p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,operaciones,plataforma,organizacion,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_empresa IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.finance','administration.receipts.validate',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Payment review denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(item ORDER BY created_at DESC,id DESC),'[]') INTO result FROM (
  SELECT p.id,p.creado_en created_at,jsonb_build_object('order_id',p.id,'number',p.numero,'version',p.version,
   'created_at',p.creado_en,'currency',p.moneda,'base_currency',c.base_currency_code,'total',p.total,
   'customer',p.cliente_snapshot,'payment',p.pago_snapshot,'branch_id',p.sucursal_id,'order_status',p.estado,
   'sale_status',v.estado,'financial_status',CASE WHEN rp.id IS NOT NULL THEN 'REFUNDED'
    WHEN p.estado='CANCELLED' AND r.estado='VALIDATED' THEN 'REFUND_REQUIRED'
    WHEN r.estado='VALIDATED' THEN 'PAYMENT_VALIDATED' WHEN r.estado='REJECTED' THEN 'PAYMENT_REJECTED'
    ELSE 'PAYMENT_PENDING_REVIEW' END,
   'refund',CASE WHEN rp.id IS NULL THEN NULL ELSE jsonb_build_object('id',rp.id,'method',rp.metodo,
    'reference',rp.referencia,'operation_id',rp.operacion_id,'movement_id',rp.movimiento_id,
    'credit_note_id',rp.nota_credito_id,'credit_note_number',nc.numero,'date',op.fecha,'recorded_at',rp.creado_en) END,
   'review',CASE WHEN r.id IS NULL THEN NULL ELSE jsonb_build_object('id',r.id,'decision',r.estado,
    'reason',r.motivo,'evidence',r.evidencia,'reviewed_by',r.creado_por,'reviewed_at',r.creado_en) END) item
  FROM operaciones.pedidos p JOIN organizacion.companies c ON c.tenant_id=p.tenant_id AND c.id=p.empresa_id
  LEFT JOIN administracion.revisiones_pago r ON (r.tenant_id,r.empresa_id,r.pedido_id)=(p.tenant_id,p.empresa_id,p.id)
  LEFT JOIN administracion.ventas_origen v ON (v.tenant_id,v.empresa_id,v.pedido_id)=(p.tenant_id,p.empresa_id,p.id)
  LEFT JOIN administracion.reembolsos_pedido rp ON (rp.tenant_id,rp.empresa_id,rp.pedido_id)=(p.tenant_id,p.empresa_id,p.id)
  LEFT JOIN administracion.operaciones_tesoreria op ON (op.tenant_id,op.empresa_id,op.id)=(rp.tenant_id,rp.empresa_id,rp.operacion_id)
  LEFT JOIN administracion.documentos nc ON (nc.tenant_id,nc.empresa_id,nc.id)=(rp.tenant_id,rp.empresa_id,rp.nota_credito_id)
  WHERE p.tenant_id=plataforma.current_app_tenant_id() AND p.empresa_id=p_empresa
  AND p.pago_snapshot->>'method' IN ('mobile','transfer','mobile_payment','bank_transfer')
  AND (p.pago_snapshot->>'status'='PENDING_VERIFICATION' OR r.id IS NOT NULL)
  ORDER BY p.creado_en DESC,p.id DESC LIMIT p_limit) pending;
 RETURN result;
END $$;
