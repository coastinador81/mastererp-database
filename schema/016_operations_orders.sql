-- Orders persistence baseline. No inventory table is invented here: creation
-- requires an opaque reservation reference issued by the Inventory owner.
CREATE SCHEMA IF NOT EXISTS operaciones;

WITH added AS (
 INSERT INTO plataforma.permissions(code,description) VALUES
 ('operations.orders.read','Read company orders'),
 ('operations.orders.write','Create and transition company orders')
 ON CONFLICT DO NOTHING RETURNING code
)
INSERT INTO plataforma.role_permissions(role_id,permission_code)
SELECT r.id,a.code FROM plataforma.roles r CROSS JOIN added a WHERE r.code='tenant.owner'
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS operaciones.pedidos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
 empresa_id uuid NOT NULL,
 sucursal_id uuid NOT NULL,
 cliente_id uuid NOT NULL,
 numero text NOT NULL CHECK(length(btrim(numero)) BETWEEN 1 AND 80),
 estado text NOT NULL CHECK(estado IN ('PENDING','CONFIRMED','PREPARING','READY','OUT_FOR_DELIVERY','DELIVERED','CANCELLED')),
 moneda char(3) NOT NULL REFERENCES catalogo.monedas(codigo),
 subtotal administracion.importe NOT NULL,
 tarifa_entrega administracion.importe NOT NULL DEFAULT 0,
 total administracion.importe GENERATED ALWAYS AS (subtotal+tarifa_entrega) STORED,
 cliente_snapshot jsonb NOT NULL CHECK(jsonb_typeof(cliente_snapshot)='object'),
 entrega_snapshot jsonb NOT NULL CHECK(jsonb_typeof(entrega_snapshot)='object'),
 pago_snapshot jsonb NOT NULL CHECK(jsonb_typeof(pago_snapshot)='object'),
 ventana_entrega_ref text NOT NULL CHECK(length(btrim(ventana_entrega_ref))>0),
 metodo_entrega text NOT NULL CHECK(metodo_entrega IN ('realtime','scheduled')),
 reserva_inventario_ref text NOT NULL CHECK(length(btrim(reserva_inventario_ref))>0),
 ruta_ref text,
 referencia_externa text,
 idempotency_key varchar(128) NOT NULL UNIQUE REFERENCES plataforma.idempotency_keys(idempotency_key) DEFERRABLE INITIALLY DEFERRED,
 creado_por uuid NOT NULL DEFAULT plataforma.current_app_user_id() REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 actualizado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 UNIQUE(tenant_id,empresa_id,id),
 UNIQUE(tenant_id,empresa_id,numero),
 UNIQUE(tenant_id,empresa_id,referencia_externa),
 FOREIGN KEY(tenant_id,empresa_id) REFERENCES organizacion.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,empresa_id,sucursal_id) REFERENCES organizacion.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,cliente_id) REFERENCES catalogo.terceros(tenant_id,id)
);
CREATE INDEX IF NOT EXISTS pedidos_empresa_estado_fecha_idx
 ON operaciones.pedidos(tenant_id,empresa_id,estado,creado_en DESC,id DESC);
CREATE INDEX IF NOT EXISTS pedidos_cliente_fecha_idx
 ON operaciones.pedidos(tenant_id,empresa_id,cliente_id,creado_en DESC,id DESC);

CREATE TABLE IF NOT EXISTS operaciones.pedido_lineas (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL,
 empresa_id uuid NOT NULL,
 pedido_id uuid NOT NULL,
 posicion integer NOT NULL CHECK(posicion>0),
 producto_id uuid NOT NULL,
 producto_nombre text NOT NULL CHECK(length(btrim(producto_nombre))>0),
 cantidad administracion.cantidad NOT NULL,
 precio_unitario administracion.importe NOT NULL,
 subtotal administracion.importe GENERATED ALWAYS AS (cantidad*precio_unitario) STORED,
 UNIQUE(tenant_id,empresa_id,id),
 UNIQUE(tenant_id,empresa_id,pedido_id,posicion),
 FOREIGN KEY(tenant_id,empresa_id,pedido_id) REFERENCES operaciones.pedidos(tenant_id,empresa_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,producto_id) REFERENCES catalogo.productos(tenant_id,id)
);

CREATE TABLE IF NOT EXISTS operaciones.pedido_eventos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL,
 empresa_id uuid NOT NULL,
 pedido_id uuid NOT NULL,
 estado_anterior text,
 estado_nuevo text NOT NULL CHECK(estado_nuevo IN ('PENDING','CONFIRMED','PREPARING','READY','OUT_FOR_DELIVERY','DELIVERED','CANCELLED')),
 motivo text NOT NULL CHECK(length(btrim(motivo)) BETWEEN 1 AND 80),
 detalle text CHECK(length(detalle)<=500),
 actor_id uuid NOT NULL REFERENCES plataforma.users(id),
 correlation_id uuid NOT NULL,
 creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 UNIQUE(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,pedido_id) REFERENCES operaciones.pedidos(tenant_id,empresa_id,id) ON DELETE RESTRICT,
 CHECK(estado_anterior IS NULL OR estado_anterior IN ('PENDING','CONFIRMED','PREPARING','READY','OUT_FOR_DELIVERY','DELIVERED','CANCELLED'))
);
CREATE INDEX IF NOT EXISTS pedido_eventos_pedido_fecha_idx
 ON operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,creado_en,id);

ALTER TABLE operaciones.pedidos ENABLE ROW LEVEL SECURITY;
ALTER TABLE operaciones.pedido_lineas ENABLE ROW LEVEL SECURITY;
ALTER TABLE operaciones.pedido_eventos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA operaciones FROM mastererp_app;
GRANT USAGE ON SCHEMA operaciones TO mastererp_app;

CREATE OR REPLACE FUNCTION operaciones.pedidos_leer(
 p_empresa uuid,p_id uuid DEFAULT NULL,p_estado text DEFAULT NULL,
 p_limit integer DEFAULT 25,p_after timestamptz DEFAULT NULL,p_after_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,organizacion,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_empresa IS NULL OR p_limit NOT BETWEEN 1 AND 101
 OR (p_estado IS NOT NULL AND p_estado NOT IN ('PENDING','CONFIRMED','PREPARING','READY','OUT_FOR_DELIVERY','DELIVERED','CANCELLED'))
 OR ((p_after IS NULL)<>(p_after_id IS NULL)) THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.orders.read',p_empresa) IS NOT TRUE THEN
  RAISE EXCEPTION 'Order access denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(item ORDER BY creado_en DESC,id DESC),'[]') INTO result FROM (
  SELECT p.id,p.creado_en,jsonb_build_object(
   'id',p.id,'company_id',p.empresa_id,'branch_id',p.sucursal_id,'customer_id',p.cliente_id,
   'number',p.numero,'status',p.estado,'currency',p.moneda,'subtotal',p.subtotal,
   'delivery_fee',p.tarifa_entrega,'total',p.total,'customer_snapshot',p.cliente_snapshot,
   'delivery_snapshot',p.entrega_snapshot,'payment_snapshot',p.pago_snapshot,
   'delivery_window_ref',p.ventana_entrega_ref,'delivery_method',p.metodo_entrega,
   'route_ref',p.ruta_ref,'external_reference',p.referencia_externa,
   'created_at',p.creado_en,'updated_at',p.actualizado_en,'version',p.version,
   'items',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',l.id,'position',l.posicion,
    'product_id',l.producto_id,'product_name',l.producto_nombre,'quantity',l.cantidad,
    'unit_price',l.precio_unitario,'subtotal',l.subtotal) ORDER BY l.posicion),'[]')
    FROM operaciones.pedido_lineas l WHERE l.pedido_id=p.id)
  ) item FROM operaciones.pedidos p
  WHERE p.tenant_id=plataforma.current_app_tenant_id() AND p.empresa_id=p_empresa
  AND (p_id IS NULL OR p.id=p_id) AND (p_estado IS NULL OR p.estado=p_estado)
  AND (p_after IS NULL OR (p.creado_en,p.id)<(p_after,p_after_id))
  ORDER BY p.creado_en DESC,p.id DESC LIMIT p_limit
 ) q;
 IF p_id IS NOT NULL AND jsonb_array_length(result)=0 THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 RETURN CASE WHEN p_id IS NULL THEN result ELSE result->0 END;
END $$;

CREATE OR REPLACE FUNCTION operaciones.pedido_crear(
 p_empresa uuid,p_sucursal uuid,p_cliente uuid,p_moneda char(3),p_items jsonb,
 p_cliente_snapshot jsonb,p_entrega_snapshot jsonb,p_pago_snapshot jsonb,
 p_ventana_entrega_ref text,p_metodo_entrega text,p_reserva_inventario_ref text,
 p_tarifa_entrega administracion.importe,p_referencia_externa text,p_idempotency_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id();
 order_id uuid:=gen_random_uuid(); operation text:='operations.orders.create'; correlation uuid;
 fingerprint text; cached plataforma.idempotency_keys%ROWTYPE; subtotal_value administracion.importe;
BEGIN
 IF p_empresa IS NULL OR p_sucursal IS NULL OR p_cliente IS NULL OR p_moneda IS NULL
 OR jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)=0
 OR jsonb_typeof(p_cliente_snapshot)<>'object' OR jsonb_typeof(p_entrega_snapshot)<>'object'
 OR jsonb_typeof(p_pago_snapshot)<>'object' OR p_metodo_entrega NOT IN ('realtime','scheduled')
 OR length(btrim(p_ventana_entrega_ref))=0 OR length(btrim(p_reserva_inventario_ref))=0
 OR length(p_idempotency_key) NOT BETWEEN 1 AND 128 OR COALESCE(p_tarifa_entrega,0)<0
 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.operations','operations.orders.write',p_empresa) IS NOT TRUE THEN
  RAISE EXCEPTION 'Order creation denied' USING ERRCODE='42501'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM operation THEN
  RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL THEN RAISE EXCEPTION 'Correlation required' USING ERRCODE='22023'; END IF;
 fingerprint:=encode(public.digest(jsonb_build_object('company',p_empresa,'branch',p_sucursal,'customer',p_cliente,
  'currency',p_moneda,'items',p_items,'customer_snapshot',p_cliente_snapshot,'delivery_snapshot',p_entrega_snapshot,
  'payment_snapshot',p_pago_snapshot,'delivery_window',p_ventana_entrega_ref,'delivery_method',p_metodo_entrega,
  'inventory_reservation',p_reserva_inventario_ref,'delivery_fee',p_tarifa_entrega,
  'external_reference',p_referencia_externa)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
 SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF cached.actor_user_id<>actor OR cached.request_tenant_id<>tenant OR cached.operation<>operation
  OR cached.request_fingerprint<>fingerprint THEN RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505'; END IF;
  IF cached.response_payload IS NULL THEN RAISE EXCEPTION 'Incomplete idempotency record' USING ERRCODE='23505'; END IF;
  RETURN cached.response_payload;
 END IF;
 SELECT sum((item->>'quantity')::administracion.cantidad*(item->>'unit_price')::administracion.importe)
 INTO subtotal_value FROM jsonb_array_elements(p_items) item
 WHERE jsonb_typeof(item)='object' AND item ?& ARRAY['product_id','product_name','quantity','unit_price'];
 IF subtotal_value IS NULL OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_items) item
  WHERE jsonb_typeof(item)<>'object' OR NOT(item ?& ARRAY['product_id','product_name','quantity','unit_price'])
  OR (item->>'quantity')::numeric<=0 OR (item->>'unit_price')::numeric<0 OR length(btrim(item->>'product_name'))=0)
 THEN RAISE EXCEPTION 'Invalid order items' USING ERRCODE='22023'; END IF;
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(p_idempotency_key,actor,operation,order_id,fingerprint,tenant);
 INSERT INTO operaciones.pedidos(id,tenant_id,empresa_id,sucursal_id,cliente_id,numero,estado,moneda,subtotal,
  tarifa_entrega,cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,
  reserva_inventario_ref,referencia_externa,idempotency_key,creado_por)
 VALUES(order_id,tenant,p_empresa,p_sucursal,p_cliente,'ORD-'||upper(substr(replace(order_id::text,'-',''),1,12)),
  'PENDING',p_moneda,subtotal_value,COALESCE(p_tarifa_entrega,0),p_cliente_snapshot,p_entrega_snapshot,p_pago_snapshot,
  btrim(p_ventana_entrega_ref),p_metodo_entrega,btrim(p_reserva_inventario_ref),NULLIF(btrim(p_referencia_externa),''),p_idempotency_key,actor);
 INSERT INTO operaciones.pedido_lineas(tenant_id,empresa_id,pedido_id,posicion,producto_id,producto_nombre,cantidad,precio_unitario)
 SELECT tenant,p_empresa,order_id,ordinality,(item->>'product_id')::uuid,btrim(item->>'product_name'),
  (item->>'quantity')::administracion.cantidad,(item->>'unit_price')::administracion.importe
 FROM jsonb_array_elements(p_items) WITH ORDINALITY AS source(item,ordinality);
 INSERT INTO operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,estado_nuevo,motivo,actor_id,correlation_id)
 VALUES(tenant,p_empresa,order_id,'PENDING','ORDER_CREATED',actor,correlation);
 UPDATE plataforma.idempotency_keys SET response_payload=operaciones.pedidos_leer(p_empresa,order_id)
 WHERE idempotency_key=p_idempotency_key RETURNING response_payload INTO cached.response_payload;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.3.1-orders','pedido',order_id,operation,correlation,jsonb_build_object('empresa_id',p_empresa,'resultado','succeeded'));
 RETURN cached.response_payload;
END $$;

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
 allowed:=(current.estado,p_estado) IN (('PENDING','CONFIRMED'),('PENDING','CANCELLED'),
  ('CONFIRMED','PREPARING'),('CONFIRMED','CANCELLED'),('PREPARING','READY'),
  ('PREPARING','CANCELLED'),('READY','OUT_FOR_DELIVERY'),('OUT_FOR_DELIVERY','DELIVERED'));
 IF NOT allowed THEN RAISE EXCEPTION 'Invalid order transition' USING ERRCODE='23514'; END IF;
 IF current.estado='PENDING' AND p_estado='CONFIRMED' AND NOT (
  current.pago_snapshot->>'method'='cash' AND current.pago_snapshot->>'status'='PENDING_COLLECTION'
  OR current.pago_snapshot->>'method' IN ('mobile_payment','bank_transfer') AND current.pago_snapshot->>'status'='VALIDATED')
 THEN RAISE EXCEPTION 'Payment not ready' USING ERRCODE='23514'; END IF;
 UPDATE operaciones.pedidos SET estado=p_estado,version=version+1,actualizado_en=transaction_timestamp() WHERE id=p_id;
 INSERT INTO operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,estado_anterior,estado_nuevo,motivo,detalle,actor_id,correlation_id)
 VALUES(tenant,p_empresa,p_id,current.estado,p_estado,btrim(p_motivo),NULLIF(btrim(p_detalle),''),actor,correlation);
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.3.1-orders','pedido',p_id,'operations.orders.transition',correlation,
  jsonb_build_object('empresa_id',p_empresa,'estado_anterior',current.estado,'estado_nuevo',p_estado,'resultado','succeeded'));
 RETURN operaciones.pedidos_leer(p_empresa,p_id);
END $$;

REVOKE ALL ON FUNCTION operaciones.pedidos_leer(uuid,uuid,text,integer,timestamptz,uuid),
 operaciones.pedido_crear(uuid,uuid,uuid,char,jsonb,jsonb,jsonb,jsonb,text,text,text,administracion.importe,text,varchar),
 operaciones.pedido_transicionar(uuid,uuid,bigint,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operaciones.pedidos_leer(uuid,uuid,text,integer,timestamptz,uuid),
 operaciones.pedido_crear(uuid,uuid,uuid,char,jsonb,jsonb,jsonb,jsonb,text,text,text,administracion.importe,text,varchar),
 operaciones.pedido_transicionar(uuid,uuid,bigint,text,text,text) TO mastererp_app;
