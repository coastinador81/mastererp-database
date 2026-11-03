-- Node-scoped stock. Product metadata remains in catalogo.productos.
CREATE TABLE IF NOT EXISTS catalogo.inventarios (
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, nodo_id uuid NOT NULL, producto_id uuid NOT NULL,
 existencia numeric NOT NULL DEFAULT 0 CHECK(existencia>=0 AND scale(existencia)<=6),
 reservado numeric NOT NULL DEFAULT 0 CHECK(reservado>=0 AND reservado<=existencia AND scale(reservado)<=6),
 disponible numeric GENERATED ALWAYS AS (existencia-reservado) STORED,
 ventas_habilitadas boolean NOT NULL DEFAULT true,
 actualizado_por uuid NOT NULL REFERENCES plataforma.users(id),
 actualizado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 PRIMARY KEY(tenant_id,empresa_id,nodo_id,producto_id),
 FOREIGN KEY(tenant_id,empresa_id,nodo_id) REFERENCES operaciones.nodos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,producto_id) REFERENCES catalogo.productos(tenant_id,id)
);
CREATE INDEX IF NOT EXISTS inventarios_producto_idx ON catalogo.inventarios(tenant_id,producto_id,nodo_id);

CREATE TABLE IF NOT EXISTS catalogo.movimientos_inventario (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, empresa_id uuid NOT NULL,
 nodo_id uuid NOT NULL, producto_id uuid NOT NULL, tipo text NOT NULL CHECK(tipo IN ('SET','ADJUST','RESERVE','RELEASE','COMMIT')),
 cantidad numeric NOT NULL CHECK(cantidad<>0 AND scale(cantidad)<=6), anterior numeric NOT NULL, nuevo numeric NOT NULL,
 motivo text NOT NULL CHECK(length(btrim(motivo)) BETWEEN 1 AND 500), referencia text,
 actor_id uuid NOT NULL REFERENCES plataforma.users(id), correlation_id uuid NOT NULL,
 creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 FOREIGN KEY(tenant_id,empresa_id,nodo_id,producto_id) REFERENCES catalogo.inventarios(tenant_id,empresa_id,nodo_id,producto_id)
);
CREATE INDEX IF NOT EXISTS movimientos_inventario_scope_idx ON catalogo.movimientos_inventario(tenant_id,empresa_id,nodo_id,producto_id,creado_en DESC,id DESC);

CREATE TABLE IF NOT EXISTS catalogo.reservas_inventario (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, nodo_id uuid NOT NULL,
 estado text NOT NULL DEFAULT 'ACTIVE' CHECK(estado IN ('ACTIVE','RELEASED','COMMITTED')),
 referencia_externa text, idempotency_key varchar(128) NOT NULL UNIQUE REFERENCES plataforma.idempotency_keys(idempotency_key) DEFERRABLE INITIALLY DEFERRED,
 creado_por uuid NOT NULL REFERENCES plataforma.users(id), creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(), actualizado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 UNIQUE(tenant_id,empresa_id,id), FOREIGN KEY(tenant_id,empresa_id,nodo_id) REFERENCES operaciones.nodos(tenant_id,empresa_id,id)
);
CREATE TABLE IF NOT EXISTS catalogo.reserva_inventario_lineas (
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, reserva_id uuid NOT NULL, nodo_id uuid NOT NULL, producto_id uuid NOT NULL,
 cantidad numeric NOT NULL CHECK(cantidad>0 AND scale(cantidad)<=6), PRIMARY KEY(tenant_id,empresa_id,reserva_id,producto_id),
 FOREIGN KEY(tenant_id,empresa_id,reserva_id) REFERENCES catalogo.reservas_inventario(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,nodo_id,producto_id) REFERENCES catalogo.inventarios(tenant_id,empresa_id,nodo_id,producto_id)
);
ALTER TABLE catalogo.inventarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalogo.movimientos_inventario ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalogo.reservas_inventario ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalogo.reserva_inventario_lineas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON catalogo.inventarios,catalogo.movimientos_inventario,catalogo.reservas_inventario,catalogo.reserva_inventario_lineas FROM PUBLIC,mastererp_app;

INSERT INTO plataforma.permissions(code,description) VALUES
 ('catalog.inventory.read','Read node inventory'),('catalog.inventory.write','Adjust node inventory'),
 ('catalog.inventory.reserve','Reserve, release and commit node inventory') ON CONFLICT(code) DO NOTHING;

CREATE OR REPLACE FUNCTION catalogo.inventario_leer(p_empresa uuid,p_nodo uuid,p_producto uuid DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_empresa IS NULL OR p_nodo IS NULL OR p_limit NOT BETWEEN 1 AND 201 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.inventory.read',p_empresa,p_nodo) IS NOT TRUE THEN RAISE EXCEPTION 'Inventory access denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('company_id',i.empresa_id,'node_id',i.nodo_id,'product_id',i.producto_id,
  'product_code',p.codigo,'product_name',p.nombre,'stock',i.existencia,'reserved',i.reservado,'available',i.disponible,
  'sales_enabled',i.ventas_habilitadas,'updated_at',i.actualizado_en,'version',i.version) ORDER BY p.nombre,p.id),'[]') INTO result
 FROM catalogo.inventarios i JOIN catalogo.productos p ON p.tenant_id=i.tenant_id AND p.id=i.producto_id
 WHERE i.tenant_id=plataforma.current_app_tenant_id() AND i.empresa_id=p_empresa AND i.nodo_id=p_nodo
 AND (p_producto IS NULL OR i.producto_id=p_producto) LIMIT p_limit;
 IF p_producto IS NOT NULL AND jsonb_array_length(result)=0 THEN RAISE EXCEPTION 'Inventory not found' USING ERRCODE='P0002'; END IF;
 RETURN CASE WHEN p_producto IS NULL THEN result ELSE result->0 END;
END $$;

CREATE OR REPLACE FUNCTION catalogo.inventario_establecer(p_empresa uuid,p_nodo uuid,p_producto uuid,p_cantidad numeric,p_version bigint,p_motivo text,p_idempotency_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id(); correlation uuid;
 current catalogo.inventarios%ROWTYPE; fingerprint text; cached plataforma.idempotency_keys%ROWTYPE; response jsonb;
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
  INSERT INTO catalogo.inventarios(tenant_id,empresa_id,nodo_id,producto_id,existencia,actualizado_por) VALUES(tenant,p_empresa,p_nodo,p_producto,p_cantidad,actor);
  current.existencia:=0;
 ELSE
  IF p_version IS NULL OR current.version<>p_version THEN RAISE EXCEPTION 'Stale inventory version' USING ERRCODE='40001'; END IF;
  IF p_cantidad<current.reservado THEN RAISE EXCEPTION 'Stock below reservations' USING ERRCODE='23514'; END IF;
  UPDATE catalogo.inventarios SET existencia=p_cantidad,version=version+1,actualizado_por=actor,actualizado_en=transaction_timestamp()
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND nodo_id=p_nodo AND producto_id=p_producto;
 END IF;
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(p_idempotency_key,actor,'catalog.inventory.set',p_producto,fingerprint,tenant);
 INSERT INTO catalogo.movimientos_inventario(tenant_id,empresa_id,nodo_id,producto_id,tipo,cantidad,anterior,nuevo,motivo,actor_id,correlation_id)
 VALUES(tenant,p_empresa,p_nodo,p_producto,'SET',p_cantidad-current.existencia,current.existencia,p_cantidad,btrim(p_motivo),actor,correlation);
 response:=catalogo.inventario_leer(p_empresa,p_nodo,p_producto);
 UPDATE plataforma.idempotency_keys SET response_payload=response WHERE idempotency_key=p_idempotency_key;
 RETURN response;
END $$;

CREATE OR REPLACE FUNCTION catalogo.inventario_reservar(p_empresa uuid,p_nodo uuid,p_items jsonb,p_referencia text,p_idempotency_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id(); correlation uuid; reservation_id uuid:=gen_random_uuid();
 fingerprint text; cached plataforma.idempotency_keys%ROWTYPE; line record; current catalogo.inventarios%ROWTYPE; response jsonb;
BEGIN
 IF jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)=0 OR length(p_idempotency_key) NOT BETWEEN 1 AND 128 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.inventory.reserve',p_empresa,p_nodo) IS NOT TRUE THEN RAISE EXCEPTION 'Inventory reservation denied' USING ERRCODE='42501'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'catalog.inventory.reserve' THEN RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 fingerprint:=encode(public.digest(jsonb_build_object('company',p_empresa,'node',p_nodo,'items',p_items,'reference',p_referencia)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
 SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF cached.actor_user_id<>actor OR cached.request_tenant_id<>tenant OR cached.operation<>'catalog.inventory.reserve' OR cached.request_fingerprint<>fingerprint THEN RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505'; END IF;
  RETURN cached.response_payload;
 END IF;
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(p_idempotency_key,actor,'catalog.inventory.reserve',reservation_id,fingerprint,tenant);
 INSERT INTO catalogo.reservas_inventario(id,tenant_id,empresa_id,nodo_id,referencia_externa,idempotency_key,creado_por)
 VALUES(reservation_id,tenant,p_empresa,p_nodo,NULLIF(btrim(p_referencia),''),p_idempotency_key,actor);
 FOR line IN SELECT (item->>'product_id')::uuid product_id,(item->>'quantity')::numeric quantity FROM jsonb_array_elements(p_items) item ORDER BY item->>'product_id' LOOP
  IF line.quantity<=0 OR scale(line.quantity)>6 THEN RAISE EXCEPTION 'Invalid reservation quantity' USING ERRCODE='22023'; END IF;
  SELECT * INTO current FROM catalogo.inventarios WHERE tenant_id=tenant AND empresa_id=p_empresa AND nodo_id=p_nodo AND producto_id=line.product_id FOR UPDATE;
  IF NOT FOUND OR current.ventas_habilitadas IS NOT TRUE OR current.disponible<line.quantity THEN RAISE EXCEPTION 'Insufficient inventory' USING ERRCODE='23514'; END IF;
  UPDATE catalogo.inventarios SET reservado=reservado+line.quantity,version=version+1,actualizado_por=actor,actualizado_en=transaction_timestamp()
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND nodo_id=p_nodo AND producto_id=line.product_id;
  INSERT INTO catalogo.reserva_inventario_lineas VALUES(tenant,p_empresa,reservation_id,p_nodo,line.product_id,line.quantity);
  INSERT INTO catalogo.movimientos_inventario(tenant_id,empresa_id,nodo_id,producto_id,tipo,cantidad,anterior,nuevo,motivo,referencia,actor_id,correlation_id)
  VALUES(tenant,p_empresa,p_nodo,line.product_id,'RESERVE',line.quantity,current.reservado,current.reservado+line.quantity,'ORDER_RESERVATION',reservation_id::text,actor,correlation);
 END LOOP;
 response:=jsonb_build_object('reservation_ref',reservation_id,'status','ACTIVE','items',p_items);
 UPDATE plataforma.idempotency_keys SET response_payload=response WHERE idempotency_key=p_idempotency_key;
 RETURN response;
END $$;

CREATE OR REPLACE FUNCTION catalogo.inventario_reserva_finalizar(p_empresa uuid,p_reserva uuid,p_accion text,p_motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,catalogo,plataforma,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id(); correlation uuid; reservation catalogo.reservas_inventario%ROWTYPE; line record; current catalogo.inventarios%ROWTYPE;
BEGIN
 IF p_accion NOT IN ('RELEASE','COMMIT') OR length(btrim(p_motivo)) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 SELECT * INTO reservation FROM catalogo.reservas_inventario WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_reserva FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found' USING ERRCODE='P0002'; END IF;
 IF plataforma.has_current_tenant_capability('erp.catalog','catalog.inventory.reserve',p_empresa,reservation.nodo_id) IS NOT TRUE THEN RAISE EXCEPTION 'Inventory reservation denied' USING ERRCODE='42501'; END IF;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'catalog.inventory.reservation.finalize' THEN RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 IF reservation.estado<>'ACTIVE' THEN RETURN jsonb_build_object('reservation_ref',p_reserva,'status',reservation.estado); END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 FOR line IN SELECT * FROM catalogo.reserva_inventario_lineas WHERE tenant_id=tenant AND empresa_id=p_empresa AND reserva_id=p_reserva ORDER BY producto_id LOOP
  SELECT * INTO current FROM catalogo.inventarios WHERE tenant_id=tenant AND empresa_id=p_empresa AND nodo_id=line.nodo_id AND producto_id=line.producto_id FOR UPDATE;
  UPDATE catalogo.inventarios SET reservado=reservado-line.cantidad,
   existencia=CASE WHEN p_accion='COMMIT' THEN existencia-line.cantidad ELSE existencia END,
   version=version+1,actualizado_por=actor,actualizado_en=transaction_timestamp()
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND nodo_id=line.nodo_id AND producto_id=line.producto_id;
  INSERT INTO catalogo.movimientos_inventario(tenant_id,empresa_id,nodo_id,producto_id,tipo,cantidad,anterior,nuevo,motivo,referencia,actor_id,correlation_id)
  VALUES(tenant,p_empresa,line.nodo_id,line.producto_id,p_accion,-line.cantidad,current.reservado,current.reservado-line.cantidad,btrim(p_motivo),p_reserva::text,actor,correlation);
 END LOOP;
 UPDATE catalogo.reservas_inventario SET estado=CASE WHEN p_accion='COMMIT' THEN 'COMMITTED' ELSE 'RELEASED' END,actualizado_en=transaction_timestamp() WHERE id=p_reserva;
 RETURN jsonb_build_object('reservation_ref',p_reserva,'status',CASE WHEN p_accion='COMMIT' THEN 'COMMITTED' ELSE 'RELEASED' END);
END $$;

REVOKE ALL ON FUNCTION catalogo.inventario_leer(uuid,uuid,uuid,integer),catalogo.inventario_establecer(uuid,uuid,uuid,numeric,bigint,text,varchar),catalogo.inventario_reservar(uuid,uuid,jsonb,text,varchar),catalogo.inventario_reserva_finalizar(uuid,uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION catalogo.inventario_leer(uuid,uuid,uuid,integer),catalogo.inventario_establecer(uuid,uuid,uuid,numeric,bigint,text,varchar),catalogo.inventario_reservar(uuid,uuid,jsonb,text,varchar),catalogo.inventario_reserva_finalizar(uuid,uuid,text,text) TO mastererp_app;
