-- Candidate only. No backfill, no role assignments, no changes to applied migrations.
INSERT INTO plataforma.permissions(code,description) VALUES
 ('administration.sales.write','Register and cancel sales from authorized company orders')
ON CONFLICT(code) DO NOTHING;

CREATE TABLE IF NOT EXISTS administracion.ventas_origen (
 tenant_id uuid NOT NULL, empresa_id uuid NOT NULL, pedido_id uuid NOT NULL,
 venta_id uuid NOT NULL, origen_sistema text NOT NULL CHECK(length(btrim(origen_sistema)) BETWEEN 1 AND 80),
 estado text NOT NULL DEFAULT 'ACTIVE' CHECK(estado IN ('ACTIVE','CANCELLED')),
 cliente_snapshot jsonb NOT NULL CHECK(jsonb_typeof(cliente_snapshot)='object'),
 creado_por uuid NOT NULL REFERENCES plataforma.users(id),
 creado_en timestamptz NOT NULL DEFAULT transaction_timestamp(),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 cancelado_por uuid REFERENCES plataforma.users(id), cancelado_en timestamptz, motivo_cancelacion text,
 PRIMARY KEY(tenant_id,empresa_id,pedido_id), UNIQUE(tenant_id,empresa_id,venta_id),
 FOREIGN KEY(tenant_id,empresa_id,pedido_id) REFERENCES operaciones.pedidos(tenant_id,empresa_id,id),
 FOREIGN KEY(tenant_id,empresa_id,venta_id) REFERENCES administracion.documentos(tenant_id,empresa_id,id),
 CHECK((estado='ACTIVE' AND cancelado_por IS NULL AND cancelado_en IS NULL AND motivo_cancelacion IS NULL)
 OR (estado='CANCELLED' AND cancelado_por IS NOT NULL AND cancelado_en IS NOT NULL AND motivo_cancelacion IS NOT NULL
 AND length(btrim(motivo_cancelacion)) BETWEEN 1 AND 300))
);
ALTER TABLE administracion.ventas_origen ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON administracion.ventas_origen FROM PUBLIC,mastererp_app;
GRANT SELECT ON administracion.ventas_origen TO mastererp_app;
DROP POLICY IF EXISTS lectura_autorizada ON administracion.ventas_origen;
CREATE POLICY lectura_autorizada ON administracion.ventas_origen FOR SELECT TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id()
 AND plataforma.has_current_tenant_capability('erp.finance','administration.read',empresa_id));

CREATE OR REPLACE FUNCTION administracion.venta_desde_pedido(
 p_empresa uuid,p_pedido uuid,p_version bigint,p_idempotency_key varchar,
 p_fecha date,p_tipo_cambio numeric DEFAULT NULL,p_cambio_fecha date DEFAULT NULL,
 p_cambio_fuente text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,operaciones,plataforma,organizacion,catalogo,auditoria,pg_temp AS $$
DECLARE
 tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 correlation uuid; pedido operaciones.pedidos%ROWTYPE; cached plataforma.idempotency_keys%ROWTYPE;
 sale uuid:=gen_random_uuid(); fingerprint text; response jsonb; base char(3); rate numeric;
 rate_date date; rate_source text; initial_operation text; ignored jsonb;
BEGIN
 initial_operation:=NULLIF(current_setting('app.current_operation',true),'');
 IF initial_operation IS DISTINCT FROM 'administracion.documento.venta.crear'
 OR plataforma.has_current_tenant_capability('erp.finance','administration.sales.write',p_empresa) IS NOT TRUE
 OR plataforma.has_current_tenant_capability('erp.operations','operations.orders.write',p_empresa) IS NOT TRUE
 OR plataforma.has_current_tenant_capability('erp.operations','operations.orders.read',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Sale command denied' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF p_empresa IS NULL OR p_pedido IS NULL OR p_version IS NULL OR p_version<1 OR p_fecha IS NULL
 OR correlation IS NULL OR p_idempotency_key IS NULL OR length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 100
 THEN RAISE EXCEPTION 'Invalid sale command' USING ERRCODE='22023'; END IF;
 fingerprint:=encode(public.digest(jsonb_build_object('empresa',p_empresa,'pedido',p_pedido,
  'version',p_version,'fecha',p_fecha,'cambio',p_tipo_cambio,'cambio_fecha',p_cambio_fecha,
  'cambio_fuente',p_cambio_fuente)::text,'sha256'),'hex');
 -- Company -> idempotency key -> order -> document. Same-key calls serialize before lookup.
 SELECT base_currency_code INTO base FROM organizacion.companies
 WHERE tenant_id=tenant AND id=p_empresa AND status='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Company not found' USING ERRCODE='42501'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
 SELECT * INTO pedido FROM operaciones.pedidos
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 IF plataforma.has_current_tenant_capability('erp.finance','administration.sales.write',p_empresa,pedido.sucursal_id) IS NOT TRUE
 THEN RAISE EXCEPTION 'Sale branch denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF cached.actor_user_id IS DISTINCT FROM actor OR cached.request_tenant_id IS DISTINCT FROM tenant
  OR cached.operation IS DISTINCT FROM initial_operation OR cached.request_fingerprint IS DISTINCT FROM fingerprint
  OR cached.expires_at<=transaction_timestamp() OR cached.response_payload IS NULL
  THEN RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505'; END IF;
  RETURN cached.response_payload;
 END IF;
 IF pedido.version<>p_version THEN RAISE EXCEPTION 'Stale order version' USING ERRCODE='40001'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.ventas_origen
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND pedido_id=p_pedido)
 THEN RAISE EXCEPTION 'Order already has a sale' USING ERRCODE='23505'; END IF;
 -- Do not guess origin from a browser parameter or customer role.
 IF NOT EXISTS(SELECT 1 FROM operaciones.pedido_eventos WHERE tenant_id=tenant AND empresa_id=p_empresa
 AND pedido_id=p_pedido AND motivo='STOREFRONT_CHECKOUT' AND estado_nuevo='PENDING')
 THEN RAISE EXCEPTION 'Unsupported order origin' USING ERRCODE='22023'; END IF;
 IF NOT EXISTS(SELECT 1 FROM administracion.perfiles_tercero WHERE tenant_id=tenant
 AND empresa_id=p_empresa AND tercero_id=pedido.cliente_id AND rol='cliente')
 THEN RAISE EXCEPTION 'Customer company profile required' USING ERRCODE='23514'; END IF;
 IF pedido.moneda=base THEN
  IF p_tipo_cambio IS NOT NULL AND p_tipo_cambio<>1 THEN
   RAISE EXCEPTION 'Same-currency exchange rate must be one' USING ERRCODE='22023'; END IF;
  rate:=1; rate_date:=p_fecha; rate_source:='same_currency';
 ELSE
  IF p_tipo_cambio IS NULL OR p_tipo_cambio<=0 OR scale(p_tipo_cambio)>12
  OR p_tipo_cambio>=1000000000000 OR p_cambio_fecha IS NULL
  OR length(btrim(COALESCE(p_cambio_fuente,''))) NOT BETWEEN 1 AND 150
  THEN RAISE EXCEPTION 'Explicit exchange rate, date and source required' USING ERRCODE='22023'; END IF;
  rate:=p_tipo_cambio; rate_date:=p_cambio_fecha; rate_source:=btrim(p_cambio_fuente);
 END IF;
 IF pedido.estado='PENDING' THEN
  PERFORM set_config('app.current_operation','operations.orders.transition',true);
  ignored:=operaciones.pedido_transicionar(p_empresa,p_pedido,p_version,'CONFIRMED','SALE_CONFIRMED',NULL);
  PERFORM set_config('app.current_operation',initial_operation,true);
 ELSIF pedido.estado<>'CONFIRMED' THEN
  RAISE EXCEPTION 'Confirmed order required' USING ERRCODE='23514';
 END IF;
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(p_idempotency_key,actor,initial_operation,sale,fingerprint,tenant);
 INSERT INTO administracion.documentos(id,tenant_id,empresa_id,sucursal_id,clase,tercero_id,rol_tercero,
 fecha,numero,moneda,moneda_base,tipo_cambio,cambio_fecha,cambio_fuente,total,
 origen_sistema,referencia_externa,idempotency_key,creado_por)
 VALUES(sale,tenant,p_empresa,pedido.sucursal_id,'venta',pedido.cliente_id,'cliente',p_fecha,
 'VEN-'||sale::text,pedido.moneda,base,rate,rate_date,rate_source,pedido.total,
 'ecommerce',p_pedido::text,p_idempotency_key,actor);
 INSERT INTO administracion.detalles_documento(tenant_id,empresa_id,sucursal_id,documento_id,posicion,
 producto_id,descripcion,cantidad,precio_unitario,subtotal,creado_por)
 SELECT tenant,p_empresa,pedido.sucursal_id,sale,posicion,producto_id,producto_nombre,cantidad,
 precio_unitario,subtotal,actor FROM operaciones.pedido_lineas
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND pedido_id=p_pedido;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order lines required' USING ERRCODE='23514'; END IF;
 IF pedido.tarifa_entrega>0 THEN
  INSERT INTO administracion.detalles_documento(tenant_id,empresa_id,sucursal_id,documento_id,posicion,
  descripcion,cantidad,precio_unitario,subtotal,creado_por)
  SELECT tenant,p_empresa,pedido.sucursal_id,sale,max(posicion)+1,'Entrega del pedido',1,
  pedido.tarifa_entrega,pedido.tarifa_entrega,actor FROM operaciones.pedido_lineas
  WHERE tenant_id=tenant AND empresa_id=p_empresa AND pedido_id=p_pedido;
 END IF;
 -- Seal after inserting lines. Existing deferred checks validate totals, currency and idempotency.
 UPDATE administracion.documentos SET cerrado=true,version=version+1 WHERE id=sale;
 INSERT INTO administracion.ventas_origen(tenant_id,empresa_id,pedido_id,venta_id,origen_sistema,cliente_snapshot,creado_por)
 VALUES(tenant,p_empresa,p_pedido,sale,'ecommerce',pedido.cliente_snapshot,actor);
 response:=jsonb_build_object('id',sale,'pedido_id',p_pedido,'estado','ACTIVE','version',1);
 UPDATE plataforma.idempotency_keys SET response_payload=response WHERE idempotency_key=p_idempotency_key;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.2.1.1.3-ventas','venta',sale,initial_operation,correlation,
 jsonb_build_object('empresa_id',p_empresa,'pedido_id',p_pedido,'resultado','succeeded'));
 RETURN response;
END $$;

CREATE OR REPLACE FUNCTION administracion.venta_anular(
 p_empresa uuid,p_pedido uuid,p_version bigint,p_motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,operaciones,plataforma,organizacion,catalogo,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 correlation uuid; link administracion.ventas_origen%ROWTYPE; pedido operaciones.pedidos%ROWTYPE;
BEGIN
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'administracion.venta.anular'
 OR plataforma.has_current_tenant_capability('erp.finance','administration.sales.write',p_empresa) IS NOT TRUE
 OR plataforma.has_current_tenant_capability('erp.operations','operations.orders.write',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Sale cancellation denied' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF p_empresa IS NULL OR p_pedido IS NULL OR p_version IS NULL OR p_motivo IS NULL
 OR length(btrim(p_motivo)) NOT BETWEEN 1 AND 300 OR correlation IS NULL
 THEN RAISE EXCEPTION 'Invalid cancellation' USING ERRCODE='22023'; END IF;
 PERFORM 1 FROM organizacion.companies WHERE tenant_id=tenant AND id=p_empresa FOR UPDATE;
 SELECT * INTO pedido FROM operaciones.pedidos WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_pedido FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 IF plataforma.has_current_tenant_capability('erp.finance','administration.sales.write',p_empresa,pedido.sucursal_id) IS NOT TRUE
 THEN RAISE EXCEPTION 'Sale branch denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO link FROM administracion.ventas_origen WHERE tenant_id=tenant AND empresa_id=p_empresa AND pedido_id=p_pedido FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Sale not found' USING ERRCODE='P0002'; END IF;
 IF link.version<>p_version THEN RAISE EXCEPTION 'Stale sale version' USING ERRCODE='40001'; END IF;
 IF pedido.estado<>'CANCELLED' THEN RAISE EXCEPTION 'Cancel order through Operations first' USING ERRCODE='23514'; END IF;
 PERFORM 1 FROM catalogo.reservas_inventario WHERE tenant_id=tenant AND empresa_id=p_empresa
 AND id::text=pedido.reserva_inventario_ref FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Inventory reservation must be resolved before cancellation' USING ERRCODE='23514'; END IF;
 PERFORM 1 FROM administracion.documentos WHERE id=link.venta_id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM administracion.documentos WHERE documento_origen_id=link.venta_id)
 OR EXISTS(SELECT 1 FROM administracion.relaciones_documento WHERE origen_id=link.venta_id OR destino_id=link.venta_id)
 OR EXISTS(SELECT 1 FROM administracion.partidas_cartera WHERE documento_id=link.venta_id)
 OR EXISTS(SELECT 1 FROM catalogo.reservas_inventario WHERE tenant_id=tenant AND empresa_id=p_empresa
 AND (id::text=pedido.reserva_inventario_ref OR referencia_externa=p_pedido::text) AND estado<>'RELEASED')
 THEN RAISE EXCEPTION 'Downstream effects prevent basic cancellation' USING ERRCODE='23514'; END IF;
 IF link.estado='CANCELLED' THEN RETURN jsonb_build_object('id',link.venta_id,'estado',link.estado,'version',link.version); END IF;
 UPDATE administracion.ventas_origen SET estado='CANCELLED',version=version+1,
 cancelado_por=actor,cancelado_en=transaction_timestamp(),motivo_cancelacion=btrim(p_motivo)
 WHERE tenant_id=tenant AND empresa_id=p_empresa AND pedido_id=p_pedido;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.2.1.1.3-ventas','venta',link.venta_id,'administracion.venta.anular',correlation,
 jsonb_build_object('empresa_id',p_empresa,'resultado','succeeded'));
 RETURN jsonb_build_object('id',link.venta_id,'estado','CANCELLED','version',link.version+1);
END $$;
REVOKE ALL ON FUNCTION administracion.venta_desde_pedido(uuid,uuid,bigint,varchar,date,numeric,date,text),
 administracion.venta_anular(uuid,uuid,bigint,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION administracion.venta_desde_pedido(uuid,uuid,bigint,varchar,date,numeric,date,text),
 administracion.venta_anular(uuid,uuid,bigint,text) TO mastererp_app;

-- Protect the link itself and reject future financial children of a cancelled sale.
CREATE OR REPLACE FUNCTION administracion.validar_ventas_origen() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,operaciones,pg_temp AS $$
DECLARE row_data jsonb; tenant uuid; company uuid;
BEGIN
 row_data:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 tenant:=(row_data->>'tenant_id')::uuid; company:=(row_data->>'empresa_id')::uuid;
 IF EXISTS(SELECT 1 FROM administracion.ventas_origen v
 JOIN administracion.documentos d ON (d.tenant_id,d.empresa_id,d.id)=(v.tenant_id,v.empresa_id,v.venta_id)
 JOIN operaciones.pedidos p ON (p.tenant_id,p.empresa_id,p.id)=(v.tenant_id,v.empresa_id,v.pedido_id)
 WHERE v.tenant_id=tenant AND v.empresa_id=company AND
 (d.clase<>'venta' OR d.tercero_id IS DISTINCT FROM p.cliente_id OR d.sucursal_id IS DISTINCT FROM p.sucursal_id
 OR d.moneda<>p.moneda OR d.total<>p.total OR d.origen_sistema IS DISTINCT FROM v.origen_sistema
 OR d.referencia_externa IS DISTINCT FROM p.id::text OR NOT d.cerrado))
 THEN RAISE EXCEPTION 'Sale/order link mismatch' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM administracion.ventas_origen v WHERE v.tenant_id=tenant AND v.empresa_id=company
 AND v.estado='CANCELLED' AND (
 EXISTS(SELECT 1 FROM administracion.documentos d WHERE d.documento_origen_id=v.venta_id)
 OR EXISTS(SELECT 1 FROM administracion.relaciones_documento r WHERE r.origen_id=v.venta_id OR r.destino_id=v.venta_id)
 OR EXISTS(SELECT 1 FROM administracion.partidas_cartera p WHERE p.documento_id=v.venta_id)))
 THEN RAISE EXCEPTION 'Cancelled sale cannot receive financial documents' USING ERRCODE='23514'; END IF;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION administracion.validar_ventas_origen() FROM PUBLIC,mastererp_app;
DO $$ DECLARE table_name text; BEGIN
 FOREACH table_name IN ARRAY ARRAY['ventas_origen','documentos','relaciones_documento','partidas_cartera'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS integridad_venta_origen ON administracion.%I',table_name);
  EXECUTE format('CREATE CONSTRAINT TRIGGER integridad_venta_origen AFTER INSERT OR UPDATE OR DELETE ON administracion.%I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION administracion.validar_ventas_origen()',table_name);
 END LOOP;
END $$;
