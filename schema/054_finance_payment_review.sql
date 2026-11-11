-- Finance-owned review of electronic Storefront payments.
INSERT INTO plataforma.permissions(code,description) VALUES
 ('administration.receipts.validate','Review and decide customer payment evidence')
ON CONFLICT(code) DO NOTHING;
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,'administration.receipts.validate' FROM plataforma.roles r
 WHERE r.code IN ('tenant.owner','tenant.finance_admin') ON CONFLICT DO NOTHING;
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
 WHERE r.code='tenant.owner'
 AND p.code IN ('administration.sales.write','administration.read','operations.orders.read')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS administracion.revisiones_pago (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, empresa_id uuid NOT NULL,
 pedido_id uuid NOT NULL, estado text NOT NULL CHECK(estado IN ('VALIDATED','REJECTED')),
 motivo text NOT NULL CHECK(length(btrim(motivo)) BETWEEN 1 AND 300), evidencia jsonb NOT NULL DEFAULT '{}',
 creado_por uuid NOT NULL REFERENCES plataforma.users(id), creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 idempotency_key varchar(128) NOT NULL UNIQUE REFERENCES plataforma.idempotency_keys(idempotency_key) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(tenant_id,empresa_id,pedido_id), FOREIGN KEY(tenant_id,empresa_id,pedido_id)
  REFERENCES operaciones.pedidos(tenant_id,empresa_id,id) ON DELETE RESTRICT
);
ALTER TABLE administracion.revisiones_pago ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.revisiones_pago FROM PUBLIC,mastererp_app;

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
   'created_at',p.creado_en,'currency',p.moneda,'base_currency',c.base_currency_code,'total',p.total,'customer',p.cliente_snapshot,
   'payment',p.pago_snapshot,'branch_id',p.sucursal_id,'review',CASE WHEN r.id IS NULL THEN NULL ELSE
   jsonb_build_object('id',r.id,'decision',r.estado,'reason',r.motivo,'evidence',r.evidencia,
    'reviewed_by',r.creado_por,'reviewed_at',r.creado_en) END) item
  FROM operaciones.pedidos p
  JOIN organizacion.companies c ON c.tenant_id=p.tenant_id AND c.id=p.empresa_id
  LEFT JOIN administracion.revisiones_pago r ON r.tenant_id=p.tenant_id
   AND r.empresa_id=p.empresa_id AND r.pedido_id=p.id
  WHERE p.tenant_id=plataforma.current_app_tenant_id() AND p.empresa_id=p_empresa
  AND p.pago_snapshot->>'method' IN ('mobile','transfer','mobile_payment','bank_transfer')
  AND (p.pago_snapshot->>'status'='PENDING_VERIFICATION' OR r.id IS NOT NULL)
  ORDER BY p.creado_en DESC,p.id DESC LIMIT p_limit
 ) pending;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION administracion.pago_revisar(
 p_empresa uuid,p_pedido uuid,p_version bigint,p_decision text,p_motivo text,p_evidencia jsonb,p_idempotency_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,operaciones,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 order_row operaciones.pedidos%ROWTYPE; cached plataforma.idempotency_keys%ROWTYPE; review_id uuid:=gen_random_uuid();
 fingerprint text; correlation uuid; sale jsonb; response jsonb; sale_key varchar;
 base char(3); exchange jsonb; exchange_rate numeric; exchange_date date; exchange_source text;
BEGIN
 IF p_empresa IS NULL OR p_pedido IS NULL OR p_version IS NULL OR p_version<1
 OR p_decision NOT IN ('VALIDATED','REJECTED') OR length(btrim(p_motivo)) NOT BETWEEN 1 AND 300
 OR jsonb_typeof(p_evidencia)<>'object' OR octet_length(p_evidencia::text)>10000
 OR length(p_idempotency_key) NOT BETWEEN 1 AND 128 THEN RAISE EXCEPTION 'Invalid payment review' USING ERRCODE='22023'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'administration.receipts.validate'
 OR plataforma.has_current_tenant_capability('erp.finance','administration.receipts.validate',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Payment review denied' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL THEN RAISE EXCEPTION 'Correlation required' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
 fingerprint:=encode(public.digest(jsonb_build_object('company',p_empresa,'order',p_pedido,'version',p_version,
  'decision',p_decision,'reason',btrim(p_motivo),'evidence',p_evidencia)::text,'sha256'),'hex');
 SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF cached.actor_user_id<>actor OR cached.request_tenant_id<>tenant OR cached.operation<>'administration.receipts.validate'
  OR cached.request_fingerprint<>fingerprint OR cached.response_payload IS NULL
  THEN RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505'; END IF;
  RETURN cached.response_payload;
 END IF;
 SELECT * INTO order_row FROM operaciones.pedidos WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 IF plataforma.has_current_tenant_capability('erp.finance','administration.receipts.validate',p_empresa,order_row.sucursal_id) IS NOT TRUE
 THEN RAISE EXCEPTION 'Payment branch denied' USING ERRCODE='42501'; END IF;
 IF order_row.version<>p_version THEN RAISE EXCEPTION 'Stale order version' USING ERRCODE='40001'; END IF;
 IF order_row.estado<>'PENDING' OR order_row.pago_snapshot->>'status'<>'PENDING_VERIFICATION'
 OR order_row.pago_snapshot->>'method' NOT IN ('mobile','transfer','mobile_payment','bank_transfer')
 THEN RAISE EXCEPTION 'Pending electronic payment required' USING ERRCODE='23514'; END IF;
 SELECT base_currency_code INTO base FROM organizacion.companies
 WHERE tenant_id=tenant AND id=p_empresa AND status='active';
 IF NOT FOUND THEN RAISE EXCEPTION 'Company not found' USING ERRCODE='42501'; END IF;
 exchange:=p_evidencia->'exchange_rate';
 IF p_decision='VALIDATED' AND order_row.moneda<>base THEN
  IF jsonb_typeof(exchange)<>'object' OR exchange->>'rate' IS NULL OR exchange->>'date' IS NULL
  OR length(btrim(COALESCE(exchange->>'source',''))) NOT BETWEEN 1 AND 150
  THEN RAISE EXCEPTION 'Exchange rate, date and source required' USING ERRCODE='22023'; END IF;
  exchange_rate:=(exchange->>'rate')::numeric; exchange_date:=(exchange->>'date')::date;
  exchange_source:=btrim(exchange->>'source');
 END IF;
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(p_idempotency_key,actor,'administration.receipts.validate',review_id,fingerprint,tenant);
 INSERT INTO administracion.revisiones_pago(id,tenant_id,empresa_id,pedido_id,estado,motivo,evidencia,creado_por,idempotency_key)
 VALUES(review_id,tenant,p_empresa,p_pedido,p_decision,btrim(p_motivo),p_evidencia,actor,p_idempotency_key);
 UPDATE operaciones.pedidos SET pago_snapshot=pago_snapshot||jsonb_build_object('status',p_decision,'review_id',review_id,
  'reviewed_at',transaction_timestamp(),'reviewed_by',actor),
  version=version+CASE WHEN p_decision='REJECTED' THEN 1 ELSE 0 END,actualizado_en=transaction_timestamp() WHERE id=p_pedido;
 IF p_decision='VALIDATED' THEN
  PERFORM set_config('app.current_operation','administracion.documento.venta.crear',true);
  PERFORM set_config('app.sale_confirmation_reason','PAYMENT_VALIDATED',true);
  sale_key:='payment-sale:'||review_id::text;
  sale:=administracion.venta_desde_pedido(p_empresa,p_pedido,p_version,sale_key,NULL,
   exchange_rate,exchange_date,exchange_source);
 END IF;
 PERFORM set_config('app.current_operation','administration.receipts.validate',true);
 response:=jsonb_build_object('id',review_id,'order_id',p_pedido,'decision',p_decision,'reason',btrim(p_motivo),
  'reviewed_at',transaction_timestamp(),'reviewed_by',actor,'sale',sale);
 UPDATE plataforma.idempotency_keys SET response_payload=response WHERE idempotency_key=p_idempotency_key;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.2.1.4.1-cobros','revision_pago',review_id,'administration.receipts.validate',correlation,
  jsonb_build_object('empresa_id',p_empresa,'pedido_id',p_pedido,'decision',p_decision,'resultado','succeeded'));
 RETURN response;
END $$;

REVOKE ALL ON FUNCTION administracion.pagos_pendientes_leer(uuid,integer),
 administracion.pago_revisar(uuid,uuid,bigint,text,text,jsonb,varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION administracion.pagos_pendientes_leer(uuid,integer),
 administracion.pago_revisar(uuid,uuid,bigint,text,text,jsonb,varchar) TO mastererp_app;
