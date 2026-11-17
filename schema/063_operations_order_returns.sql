-- Coordinated order returns. Orders owns the case and immutable history;
-- Inventory owns stock effects and Finance owns refund/credit-note references.
INSERT INTO plataforma.permissions(code,description) VALUES
 ('operations.returns.read','Read company order returns'),
 ('operations.returns.write','Request company order returns'),
 ('operations.returns.authorize','Authorize or reject order returns'),
 ('catalog.inventory.returns.receive','Receive returns and restore eligible stock'),
 ('administration.returns.settle','Link completed refund and credit note')
ON CONFLICT(code) DO NOTHING;

INSERT INTO plataforma.role_permissions(role_id,permission_code)
SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
WHERE r.code='tenant.owner' AND p.code IN (
 'operations.returns.read','operations.returns.write','operations.returns.authorize',
 'catalog.inventory.returns.receive','administration.returns.settle')
ON CONFLICT DO NOTHING;
INSERT INTO plataforma.role_permissions(role_id,permission_code)
SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN plataforma.permissions p
WHERE r.code='tenant.finance_admin' AND p.code IN ('operations.returns.read','administration.returns.settle')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS operaciones.devoluciones_pedido (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, empresa_id uuid NOT NULL,
 pedido_id uuid NOT NULL, numero text NOT NULL, estado text NOT NULL DEFAULT 'REQUESTED'
  CHECK(estado IN ('REQUESTED','AUTHORIZED','REJECTED','RECEIVED','COMPLETED')),
 motivo text NOT NULL CHECK(length(btrim(motivo)) BETWEEN 3 AND 500),
 nodo_recepcion_id uuid, referencia_reembolso text, referencia_nota_credito text,
 solicitado_por uuid NOT NULL REFERENCES plataforma.users(id), solicitado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 autorizado_por uuid REFERENCES plataforma.users(id), autorizado_en timestamptz,
 recibido_por uuid REFERENCES plataforma.users(id), recibido_en timestamptz,
 completado_por uuid REFERENCES plataforma.users(id), completado_en timestamptz,
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 idempotency_key varchar(128) NOT NULL UNIQUE REFERENCES plataforma.idempotency_keys(idempotency_key) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(tenant_id,empresa_id,id), UNIQUE(tenant_id,empresa_id,numero),
 FOREIGN KEY(tenant_id,empresa_id,pedido_id) REFERENCES operaciones.pedidos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,nodo_recepcion_id) REFERENCES operaciones.nodos(tenant_id,empresa_id,id),
 CHECK((estado='REQUESTED' AND autorizado_en IS NULL) OR estado<>'REQUESTED'),
 CHECK((estado<>'REJECTED') OR autorizado_en IS NOT NULL),
 CHECK((estado NOT IN ('RECEIVED','COMPLETED')) OR recibido_en IS NOT NULL),
 CHECK((estado<>'COMPLETED') OR (completado_en IS NOT NULL AND referencia_reembolso IS NOT NULL AND referencia_nota_credito IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS devoluciones_pedido_scope_idx
 ON operaciones.devoluciones_pedido(tenant_id,empresa_id,pedido_id,solicitado_en DESC,id DESC);

CREATE TABLE IF NOT EXISTS operaciones.devolucion_pedido_lineas (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, empresa_id uuid NOT NULL,
 devolucion_id uuid NOT NULL, pedido_linea_id uuid NOT NULL,
 cantidad_solicitada administracion.cantidad NOT NULL,
 cantidad_autorizada administracion.cantidad,
 cantidad_recibida administracion.cantidad,
 cantidad_reintegrada administracion.cantidad,
 condicion text CHECK(condicion IS NULL OR condicion IN ('SELLABLE','DAMAGED','INCOMPLETE','OTHER')),
 UNIQUE(tenant_id,empresa_id,id), UNIQUE(tenant_id,empresa_id,devolucion_id,pedido_linea_id),
 FOREIGN KEY(tenant_id,empresa_id,devolucion_id) REFERENCES operaciones.devoluciones_pedido(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,pedido_linea_id) REFERENCES operaciones.pedido_lineas(tenant_id,empresa_id,id),
 CHECK(cantidad_autorizada IS NULL OR cantidad_autorizada<=cantidad_solicitada),
 CHECK(cantidad_recibida IS NULL OR cantidad_recibida<=cantidad_autorizada),
 CHECK(cantidad_reintegrada IS NULL OR cantidad_reintegrada<=cantidad_recibida)
);

CREATE TABLE IF NOT EXISTS operaciones.devolucion_pedido_eventos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, empresa_id uuid NOT NULL,
 devolucion_id uuid NOT NULL, estado text NOT NULL
  CHECK(estado IN ('REQUESTED','AUTHORIZED','REJECTED','RECEIVED','COMPLETED')),
 detalle text CHECK(detalle IS NULL OR length(detalle)<=500), actor_id uuid NOT NULL REFERENCES plataforma.users(id),
 correlation_id uuid NOT NULL, creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,devolucion_id) REFERENCES operaciones.devoluciones_pedido(tenant_id,empresa_id,id)
);
CREATE INDEX IF NOT EXISTS devolucion_eventos_scope_idx
 ON operaciones.devolucion_pedido_eventos(tenant_id,empresa_id,devolucion_id,creado_en,id);

ALTER TABLE operaciones.devoluciones_pedido ENABLE ROW LEVEL SECURITY;
ALTER TABLE operaciones.devolucion_pedido_lineas ENABLE ROW LEVEL SECURITY;
ALTER TABLE operaciones.devolucion_pedido_eventos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operaciones.devoluciones_pedido,operaciones.devolucion_pedido_lineas,
 operaciones.devolucion_pedido_eventos FROM PUBLIC,mastererp_app;

CREATE OR REPLACE FUNCTION operaciones.devoluciones_leer(p_empresa uuid,p_pedido uuid,p_devolucion uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_empresa IS NULL OR p_pedido IS NULL THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.returns.read',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Return read denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(item ORDER BY solicitado_en DESC,id DESC),'[]') INTO result FROM (
  SELECT d.id,d.solicitado_en,jsonb_build_object('id',d.id,'number',d.numero,'order_id',d.pedido_id,
   'status',d.estado,'reason',d.motivo,'version',d.version,'receiving_node_id',d.nodo_recepcion_id,
   'refund_reference',d.referencia_reembolso,'credit_note_reference',d.referencia_nota_credito,
   'requested_by',d.solicitado_por,'requested_at',d.solicitado_en,'authorized_by',d.autorizado_por,
   'authorized_at',d.autorizado_en,'received_by',d.recibido_por,'received_at',d.recibido_en,
   'completed_by',d.completado_por,'completed_at',d.completado_en,
   'items',(SELECT jsonb_agg(jsonb_build_object('id',l.id,'order_item_id',l.pedido_linea_id,
    'requested_quantity',l.cantidad_solicitada,'authorized_quantity',l.cantidad_autorizada,
    'received_quantity',l.cantidad_recibida,'restocked_quantity',l.cantidad_reintegrada,
    'condition',l.condicion) ORDER BY ol.posicion)
    FROM operaciones.devolucion_pedido_lineas l JOIN operaciones.pedido_lineas ol ON ol.id=l.pedido_linea_id
    WHERE (l.tenant_id,l.empresa_id,l.devolucion_id)=(d.tenant_id,d.empresa_id,d.id)),
   'history',(SELECT jsonb_agg(jsonb_build_object('id',e.id,'status',e.estado,'detail',e.detalle,
    'actor_id',e.actor_id,'created_at',e.creado_en) ORDER BY e.creado_en,e.id)
    FROM operaciones.devolucion_pedido_eventos e
    WHERE (e.tenant_id,e.empresa_id,e.devolucion_id)=(d.tenant_id,d.empresa_id,d.id))) item
  FROM operaciones.devoluciones_pedido d WHERE d.tenant_id=plataforma.current_app_tenant_id()
   AND d.empresa_id=p_empresa AND d.pedido_id=p_pedido AND (p_devolucion IS NULL OR d.id=p_devolucion)
 ) q;
 IF p_devolucion IS NOT NULL AND jsonb_array_length(result)=0 THEN RAISE EXCEPTION 'Return not found' USING ERRCODE='P0002'; END IF;
 RETURN CASE WHEN p_devolucion IS NULL THEN result ELSE result->0 END;
END $$;

CREATE OR REPLACE FUNCTION operaciones.devolucion_solicitar(
 p_empresa uuid,p_pedido uuid,p_items jsonb,p_motivo text,p_idempotency_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,auditoria,public,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 order_row operaciones.pedidos%ROWTYPE; return_id uuid:=gen_random_uuid(); correlation uuid;
 fingerprint text; cached plataforma.idempotency_keys%ROWTYPE;
BEGIN
 IF jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)=0 OR jsonb_array_length(p_items)>100
 OR length(btrim(COALESCE(p_motivo,''))) NOT BETWEEN 3 AND 500
 OR length(p_idempotency_key) NOT BETWEEN 1 AND 128 THEN RAISE EXCEPTION 'Invalid return request' USING ERRCODE='22023'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'operations.returns.request'
 OR plataforma.has_current_tenant_capability('erp.operations','operations.returns.write',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Return request denied' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL THEN RAISE EXCEPTION 'Correlation required' USING ERRCODE='22023'; END IF;
 SELECT * INTO order_row FROM operaciones.pedidos WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 IF order_row.estado<>'DELIVERED' THEN RAISE EXCEPTION 'Delivered order required' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_items) i LEFT JOIN operaciones.pedido_lineas l
  ON l.tenant_id=tenant AND l.empresa_id=p_empresa AND l.pedido_id=p_pedido AND l.id=(i->>'order_item_id')::uuid
  WHERE jsonb_typeof(i)<>'object' OR NOT(i ?& ARRAY['order_item_id','quantity']) OR l.id IS NULL
   OR (i->>'quantity')::numeric<=0 OR (i->>'quantity')::numeric>
    l.cantidad-COALESCE((SELECT sum(dl.cantidad_autorizada) FROM operaciones.devolucion_pedido_lineas dl
     JOIN operaciones.devoluciones_pedido d ON d.id=dl.devolucion_id WHERE dl.pedido_linea_id=l.id
      AND d.estado IN ('AUTHORIZED','RECEIVED','COMPLETED')),0))
 THEN RAISE EXCEPTION 'Invalid return quantities' USING ERRCODE='23514'; END IF;
 fingerprint:=encode(digest(jsonb_build_object('company',p_empresa,'order',p_pedido,'items',p_items,
  'reason',btrim(p_motivo))::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
 SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF cached.actor_user_id<>actor OR cached.request_tenant_id<>tenant OR cached.operation<>'operations.returns.request'
   OR cached.request_fingerprint<>fingerprint OR cached.response_payload IS NULL
  THEN RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505'; END IF;
  RETURN cached.response_payload;
 END IF;
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(p_idempotency_key,actor,'operations.returns.request',return_id,fingerprint,tenant);
 INSERT INTO operaciones.devoluciones_pedido(id,tenant_id,empresa_id,pedido_id,numero,motivo,solicitado_por,idempotency_key)
 VALUES(return_id,tenant,p_empresa,p_pedido,'DEV-'||upper(substr(replace(return_id::text,'-',''),1,10)),btrim(p_motivo),actor,p_idempotency_key);
 INSERT INTO operaciones.devolucion_pedido_lineas(tenant_id,empresa_id,devolucion_id,pedido_linea_id,cantidad_solicitada)
 SELECT tenant,p_empresa,return_id,(i->>'order_item_id')::uuid,(i->>'quantity')::administracion.cantidad
 FROM jsonb_array_elements(p_items) i;
 INSERT INTO operaciones.devolucion_pedido_eventos(tenant_id,empresa_id,devolucion_id,estado,detalle,actor_id,correlation_id)
 VALUES(tenant,p_empresa,return_id,'REQUESTED',btrim(p_motivo),actor,correlation);
 UPDATE plataforma.idempotency_keys SET response_payload=operaciones.devoluciones_leer(p_empresa,p_pedido,return_id)
 WHERE idempotency_key=p_idempotency_key RETURNING response_payload INTO cached.response_payload;
 RETURN cached.response_payload;
END $$;

CREATE OR REPLACE FUNCTION operaciones.devolucion_decidir(
 p_empresa uuid,p_devolucion uuid,p_version bigint,p_decision text,p_detalle text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 current operaciones.devoluciones_pedido%ROWTYPE; correlation uuid;
BEGIN
 IF p_version<1 OR p_decision NOT IN ('AUTHORIZED','REJECTED')
 OR length(btrim(COALESCE(p_detalle,''))) NOT BETWEEN 3 AND 500
 THEN RAISE EXCEPTION 'Invalid return decision' USING ERRCODE='22023'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'operations.returns.authorize'
 OR plataforma.has_current_tenant_capability('erp.operations','operations.returns.authorize',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Return authorization denied' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 SELECT * INTO current FROM operaciones.devoluciones_pedido
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_devolucion FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Return not found' USING ERRCODE='P0002'; END IF;
 IF current.version<>p_version THEN RAISE EXCEPTION 'Stale return version' USING ERRCODE='40001'; END IF;
 IF current.estado<>'REQUESTED' THEN RAISE EXCEPTION 'Requested return required' USING ERRCODE='23514'; END IF;
 UPDATE operaciones.devoluciones_pedido SET estado=p_decision,autorizado_por=actor,
  autorizado_en=transaction_timestamp(),version=version+1 WHERE id=p_devolucion;
 IF p_decision='AUTHORIZED' THEN
  UPDATE operaciones.devolucion_pedido_lineas SET cantidad_autorizada=cantidad_solicitada
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND devolucion_id=p_devolucion;
 END IF;
 INSERT INTO operaciones.devolucion_pedido_eventos(tenant_id,empresa_id,devolucion_id,estado,detalle,actor_id,correlation_id)
 VALUES(tenant,p_empresa,p_devolucion,p_decision,btrim(p_detalle),actor,correlation);
 RETURN operaciones.devoluciones_leer(p_empresa,current.pedido_id,p_devolucion);
END $$;

ALTER TABLE catalogo.movimientos_inventario DROP CONSTRAINT IF EXISTS movimientos_inventario_tipo_check;
ALTER TABLE catalogo.movimientos_inventario ADD CONSTRAINT movimientos_inventario_tipo_check
 CHECK(tipo IN ('SET','ADJUST','RESERVE','RELEASE','COMMIT','RETURN'));

CREATE OR REPLACE FUNCTION operaciones.devolucion_recibir(
 p_empresa uuid,p_devolucion uuid,p_version bigint,p_nodo uuid,p_items jsonb,p_detalle text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,catalogo,plataforma,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 current operaciones.devoluciones_pedido%ROWTYPE; correlation uuid; item record; inventory catalogo.inventarios%ROWTYPE;
BEGIN
 IF p_version<1 OR p_nodo IS NULL OR jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)=0
 OR length(btrim(COALESCE(p_detalle,''))) NOT BETWEEN 3 AND 500
 THEN RAISE EXCEPTION 'Invalid return receipt' USING ERRCODE='22023'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'catalog.inventory.returns.receive'
 OR plataforma.has_current_tenant_capability('erp.catalog','catalog.inventory.returns.receive',p_empresa,p_nodo) IS NOT TRUE
 THEN RAISE EXCEPTION 'Return receipt denied' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 SELECT * INTO current FROM operaciones.devoluciones_pedido
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_devolucion FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Return not found' USING ERRCODE='P0002'; END IF;
 IF current.version<>p_version THEN RAISE EXCEPTION 'Stale return version' USING ERRCODE='40001'; END IF;
 IF current.estado<>'AUTHORIZED' THEN RAISE EXCEPTION 'Authorized return required' USING ERRCODE='23514'; END IF;
 IF jsonb_array_length(p_items)<>(SELECT count(*) FROM operaciones.devolucion_pedido_lineas
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND devolucion_id=p_devolucion)
 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_items) i
  LEFT JOIN operaciones.devolucion_pedido_lineas l ON l.tenant_id=tenant AND l.empresa_id=p_empresa
   AND l.devolucion_id=p_devolucion AND l.id=(i->>'return_item_id')::uuid
  WHERE jsonb_typeof(i)<>'object' OR NOT(i ?& ARRAY['return_item_id','received_quantity','restocked_quantity','condition'])
   OR l.id IS NULL OR (i->>'received_quantity')::numeric<0
   OR (i->>'received_quantity')::numeric>l.cantidad_autorizada
   OR (i->>'restocked_quantity')::numeric<0
   OR (i->>'restocked_quantity')::numeric>(i->>'received_quantity')::numeric
   OR i->>'condition' NOT IN ('SELLABLE','DAMAGED','INCOMPLETE','OTHER'))
 OR EXISTS(SELECT i->>'return_item_id' FROM jsonb_array_elements(p_items) i GROUP BY 1 HAVING count(*)>1)
 THEN RAISE EXCEPTION 'Invalid return receipt items' USING ERRCODE='23514'; END IF;
 FOR item IN SELECT l.id,l.pedido_linea_id,ol.producto_id,(i->>'received_quantity')::numeric received,
  (i->>'restocked_quantity')::numeric restocked,i->>'condition' condition
  FROM jsonb_array_elements(p_items) i JOIN operaciones.devolucion_pedido_lineas l
   ON l.id=(i->>'return_item_id')::uuid AND l.tenant_id=tenant AND l.empresa_id=p_empresa AND l.devolucion_id=p_devolucion
  JOIN operaciones.pedido_lineas ol ON ol.id=l.pedido_linea_id
 LOOP
  UPDATE operaciones.devolucion_pedido_lineas SET cantidad_recibida=item.received,
   cantidad_reintegrada=item.restocked,condicion=item.condition WHERE id=item.id;
  IF item.restocked>0 THEN
   SELECT * INTO inventory FROM catalogo.inventarios WHERE tenant_id=tenant AND empresa_id=p_empresa
    AND nodo_id=p_nodo AND producto_id=item.producto_id FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Inventory not found' USING ERRCODE='P0002'; END IF;
   UPDATE catalogo.inventarios SET existencia=existencia+item.restocked,version=version+1,
    actualizado_por=actor,actualizado_en=transaction_timestamp()
   WHERE tenant_id=tenant AND empresa_id=p_empresa AND nodo_id=p_nodo AND producto_id=item.producto_id;
   INSERT INTO catalogo.movimientos_inventario(tenant_id,empresa_id,nodo_id,producto_id,tipo,cantidad,
    anterior,nuevo,motivo,referencia,actor_id,correlation_id)
   VALUES(tenant,p_empresa,p_nodo,item.producto_id,'RETURN',item.restocked,inventory.existencia,
    inventory.existencia+item.restocked,'RETURN_RECEIVED',p_devolucion::text,actor,correlation);
  END IF;
 END LOOP;
 UPDATE operaciones.devoluciones_pedido SET estado='RECEIVED',nodo_recepcion_id=p_nodo,recibido_por=actor,
  recibido_en=transaction_timestamp(),version=version+1 WHERE id=p_devolucion;
 INSERT INTO operaciones.devolucion_pedido_eventos(tenant_id,empresa_id,devolucion_id,estado,detalle,actor_id,correlation_id)
 VALUES(tenant,p_empresa,p_devolucion,'RECEIVED',btrim(p_detalle),actor,correlation);
 RETURN operaciones.devoluciones_leer(p_empresa,current.pedido_id,p_devolucion);
END $$;

CREATE OR REPLACE FUNCTION operaciones.devolucion_completar(
 p_empresa uuid,p_devolucion uuid,p_version bigint,p_reembolso text,p_nota_credito text,p_detalle text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 current operaciones.devoluciones_pedido%ROWTYPE; correlation uuid;
BEGIN
 IF p_version<1 OR length(btrim(COALESCE(p_reembolso,''))) NOT BETWEEN 1 AND 200
 OR length(btrim(COALESCE(p_nota_credito,''))) NOT BETWEEN 1 AND 200
 OR length(btrim(COALESCE(p_detalle,''))) NOT BETWEEN 3 AND 500
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
 UPDATE operaciones.devoluciones_pedido SET estado='COMPLETED',referencia_reembolso=btrim(p_reembolso),
  referencia_nota_credito=btrim(p_nota_credito),completado_por=actor,completado_en=transaction_timestamp(),
  version=version+1 WHERE id=p_devolucion;
 INSERT INTO operaciones.devolucion_pedido_eventos(tenant_id,empresa_id,devolucion_id,estado,detalle,actor_id,correlation_id)
 VALUES(tenant,p_empresa,p_devolucion,'COMPLETED',btrim(p_detalle),actor,correlation);
 RETURN operaciones.devoluciones_leer(p_empresa,current.pedido_id,p_devolucion);
END $$;

REVOKE ALL ON FUNCTION operaciones.devoluciones_leer(uuid,uuid,uuid),
 operaciones.devolucion_solicitar(uuid,uuid,jsonb,text,varchar),
 operaciones.devolucion_decidir(uuid,uuid,bigint,text,text),
 operaciones.devolucion_recibir(uuid,uuid,bigint,uuid,jsonb,text),
 operaciones.devolucion_completar(uuid,uuid,bigint,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operaciones.devoluciones_leer(uuid,uuid,uuid),
 operaciones.devolucion_solicitar(uuid,uuid,jsonb,text,varchar),
 operaciones.devolucion_decidir(uuid,uuid,bigint,text,text),
 operaciones.devolucion_recibir(uuid,uuid,bigint,uuid,jsonb,text),
 operaciones.devolucion_completar(uuid,uuid,bigint,text,text,text) TO mastererp_app;
