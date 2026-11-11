-- Coordinated pre-fulfillment cancellation and private operational notes.
CREATE TABLE IF NOT EXISTS operaciones.pedido_notas (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL,
 empresa_id uuid NOT NULL,
 pedido_id uuid NOT NULL,
 nota text NOT NULL CHECK(length(btrim(nota)) BETWEEN 1 AND 2000),
 creado_por uuid NOT NULL REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 idempotency_key varchar(128) NOT NULL UNIQUE
  REFERENCES plataforma.idempotency_keys(idempotency_key) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,pedido_id)
  REFERENCES operaciones.pedidos(tenant_id,empresa_id,id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS pedido_notas_pedido_fecha_idx
 ON operaciones.pedido_notas(tenant_id,empresa_id,pedido_id,creado_en,id);
ALTER TABLE operaciones.pedido_notas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operaciones.pedido_notas FROM PUBLIC,mastererp_app;

CREATE OR REPLACE FUNCTION operaciones.pedido_notas_leer(p_empresa uuid,p_pedido uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_empresa IS NULL OR p_pedido IS NULL THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.orders.read',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Order notes access denied' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM operaciones.pedidos WHERE tenant_id=plataforma.current_app_tenant_id()
  AND empresa_id=p_empresa AND id=p_pedido) THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object(
  'id',n.id,'note',n.nota,'actor_id',n.creado_por,'actor_name',u.display_name,'created_at',n.creado_en)
  ORDER BY n.creado_en,n.id),'[]') INTO result
 FROM operaciones.pedido_notas n JOIN plataforma.users u ON u.id=n.creado_por
 WHERE n.tenant_id=plataforma.current_app_tenant_id() AND n.empresa_id=p_empresa AND n.pedido_id=p_pedido;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION operaciones.pedido_nota_crear(
 p_empresa uuid,p_pedido uuid,p_nota text,p_idempotency_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 operation text:='operations.orders.notes.create'; correlation uuid; note_id uuid:=gen_random_uuid();
 fingerprint text; cached plataforma.idempotency_keys%ROWTYPE; response jsonb;
BEGIN
 IF p_empresa IS NULL OR p_pedido IS NULL OR length(btrim(p_nota)) NOT BETWEEN 1 AND 2000
 OR length(p_idempotency_key) NOT BETWEEN 1 AND 128 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.orders.write',p_empresa) IS NOT TRUE
 OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM operation
 THEN RAISE EXCEPTION 'Order note creation denied' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM operaciones.pedidos WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido)
 THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL THEN RAISE EXCEPTION 'Correlation required' USING ERRCODE='22023'; END IF;
 fingerprint:=encode(public.digest(jsonb_build_object('company',p_empresa,'order',p_pedido,'note',btrim(p_nota))::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
 SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF cached.actor_user_id<>actor OR cached.request_tenant_id<>tenant OR cached.operation<>operation
  OR cached.request_fingerprint<>fingerprint OR cached.response_payload IS NULL
  THEN RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505'; END IF;
  RETURN cached.response_payload;
 END IF;
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(p_idempotency_key,actor,operation,note_id,fingerprint,tenant);
 INSERT INTO operaciones.pedido_notas(id,tenant_id,empresa_id,pedido_id,nota,creado_por,idempotency_key)
 VALUES(note_id,tenant,p_empresa,p_pedido,btrim(p_nota),actor,p_idempotency_key);
 response:=jsonb_build_object('id',note_id,'note',btrim(p_nota),'actor_id',actor,
  'actor_name',(SELECT display_name FROM plataforma.users WHERE id=actor),'created_at',transaction_timestamp());
 UPDATE plataforma.idempotency_keys SET response_payload=response WHERE idempotency_key=p_idempotency_key;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.3.1-orders','pedido_nota',note_id,operation,correlation,
  jsonb_build_object('empresa_id',p_empresa,'pedido_id',p_pedido,'resultado','succeeded'));
 RETURN response;
END $$;

CREATE OR REPLACE FUNCTION operaciones.pedido_cancelar(
 p_empresa uuid,p_pedido uuid,p_version bigint,p_motivo text,p_detalle text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,catalogo,administracion,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); current operaciones.pedidos%ROWTYPE;
 reservation catalogo.reservas_inventario%ROWTYPE; sale administracion.ventas_origen%ROWTYPE;
 inventory_result jsonb; sale_result jsonb; order_result jsonb;
BEGIN
 IF p_empresa IS NULL OR p_pedido IS NULL OR p_version IS NULL
 OR length(btrim(p_motivo)) NOT BETWEEN 1 AND 80 OR (p_detalle IS NOT NULL AND length(p_detalle)>500)
 THEN RAISE EXCEPTION 'Invalid cancellation' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.orders.write',p_empresa) IS NOT TRUE
 OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'operations.orders.cancel'
 THEN RAISE EXCEPTION 'Order cancellation denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO current FROM operaciones.pedidos
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 IF current.estado='CANCELLED' THEN RETURN operaciones.pedidos_leer(p_empresa,p_pedido); END IF;
 IF current.version<>p_version THEN RAISE EXCEPTION 'Stale order version' USING ERRCODE='40001'; END IF;
 IF current.estado NOT IN ('PENDING','CONFIRMED') THEN
  RAISE EXCEPTION 'Order already entered fulfillment' USING ERRCODE='23514'; END IF;
 SELECT * INTO reservation FROM catalogo.reservas_inventario
 WHERE tenant_id=tenant AND empresa_id=p_empresa
 AND (id::text=current.reserva_inventario_ref OR referencia_externa=current.reserva_inventario_ref) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Inventory reservation not found' USING ERRCODE='P0002'; END IF;
 PERFORM set_config('app.current_operation','catalog.inventory.reservation.finalize',true);
 inventory_result:=catalogo.inventario_reserva_finalizar(p_empresa,reservation.id,'RELEASE',btrim(p_motivo));
 PERFORM set_config('app.current_operation','operations.orders.transition',true);
 order_result:=operaciones.pedido_transicionar(p_empresa,p_pedido,p_version,'CANCELLED',p_motivo,p_detalle);
 SELECT * INTO sale FROM administracion.ventas_origen
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND pedido_id=p_pedido FOR UPDATE;
 IF FOUND THEN
  PERFORM set_config('app.current_operation','administracion.venta.anular',true);
  sale_result:=administracion.venta_anular(p_empresa,p_pedido,sale.version,btrim(p_motivo));
 END IF;
 PERFORM set_config('app.current_operation','operations.orders.cancel',true);
 RETURN order_result || jsonb_build_object('inventory',inventory_result,'sale',sale_result);
END $$;

REVOKE ALL ON FUNCTION operaciones.pedido_notas_leer(uuid,uuid),
 operaciones.pedido_nota_crear(uuid,uuid,text,varchar),
 operaciones.pedido_cancelar(uuid,uuid,bigint,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operaciones.pedido_notas_leer(uuid,uuid),
 operaciones.pedido_nota_crear(uuid,uuid,text,varchar),
 operaciones.pedido_cancelar(uuid,uuid,bigint,text,text) TO mastererp_app;
