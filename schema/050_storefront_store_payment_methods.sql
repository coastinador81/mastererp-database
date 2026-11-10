-- Store payment methods: Punto de venta (collected at delivery) and tenant-defined manual methods.
-- Forward-only replacement of 040/016/047 functions; signatures and grants are preserved.
CREATE OR REPLACE FUNCTION ventas_digitales.checkout_crear(
 p_issuer text,p_subject text,p_dominio text,p_items jsonb,p_entrega jsonb,
 p_metodo_entrega text,p_pago jsonb,p_idempotency_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,catalogo,operaciones,plataforma,auditoria,pg_temp AS $$
DECLARE
 tenant uuid:=plataforma.current_app_tenant_id(); actor uuid; customer uuid;
 store ventas_digitales.tiendas%ROWTYPE; node operaciones.nodos%ROWTYPE;
 cached plataforma.idempotency_keys%ROWTYPE; fingerprint text; correlation uuid;
 reservation_id uuid:=gen_random_uuid(); order_id uuid:=gen_random_uuid(); line record;
 inventory catalogo.inventarios%ROWTYPE; order_items jsonb; subtotal_value administracion.importe;
 currency_code char(3); response jsonb; payment_method text:=p_pago->>'method';
 payment_reference text:=p_pago->>'reference'; payment_recipient jsonb; payment_snapshot jsonb;
 custom_method jsonb;
BEGIN
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'digital_sales.storefront.checkout'
 OR p_issuer!~'^https://' OR length(p_subject) NOT BETWEEN 1 AND 255
 OR p_dominio IS NULL OR jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)=0
 OR jsonb_typeof(p_entrega)<>'object' OR length(COALESCE(btrim(p_entrega->>'address'),'')) NOT BETWEEN 1 AND 300
 OR p_metodo_entrega<>'realtime' OR jsonb_typeof(p_pago)<>'object'
 OR payment_method IS NULL OR payment_method NOT IN ('cash','pos','mobile','transfer','custom')
 OR (payment_method NOT IN ('cash','pos') AND COALESCE(payment_reference,'')!~'^[0-9]{4,40}$')
 OR (payment_method='custom' AND COALESCE(p_pago->>'methodId','')!~'^[a-z0-9-]{1,40}$')
 OR length(p_idempotency_key) NOT BETWEEN 1 AND 100 THEN
  RAISE EXCEPTION 'Invalid checkout' USING ERRCODE='22023';END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL THEN RAISE EXCEPTION 'Correlation required' USING ERRCODE='22023';END IF;
 SELECT e.user_id,l.cliente_id INTO actor,customer
 FROM plataforma.external_identities e JOIN ventas_digitales.cliente_identidades l ON l.user_id=e.user_id
 WHERE e.issuer=p_issuer AND e.subject=p_subject AND e.status='active' AND l.tenant_id=tenant;
 IF actor IS NULL THEN RAISE EXCEPTION 'Customer identity not found' USING ERRCODE='42501';END IF;
 SELECT * INTO store FROM ventas_digitales.tiendas
 WHERE tenant_id=tenant AND empresa_id=(SELECT empresa_id FROM ventas_digitales.cliente_identidades
  WHERE tenant_id=tenant AND user_id=actor) AND dominio=lower(p_dominio) AND estado='ACTIVE';
 IF NOT FOUND THEN RAISE EXCEPTION 'Store not found' USING ERRCODE='P0002';END IF;
 IF payment_method='cash' THEN
  IF COALESCE((store.configuracion->'payments'->>'efectivo')::boolean,true)=false
   AND COALESCE((store.configuracion->'payments'->>'al-recibir')::boolean,true)=false
  THEN RAISE EXCEPTION 'Payment method unavailable' USING ERRCODE='22023';END IF;
  payment_snapshot:=jsonb_build_object('method','cash','status','PENDING_COLLECTION');
 ELSIF payment_method='pos' THEN
  IF COALESCE(store.configuracion->'payments'->'punto-venta-entrega','false'::jsonb)<>'true'::jsonb
  THEN RAISE EXCEPTION 'Payment method unavailable' USING ERRCODE='22023';END IF;
  payment_snapshot:=jsonb_build_object('method','pos','status','PENDING_COLLECTION','moment','delivery');
 ELSIF payment_method='custom' THEN
  SELECT m INTO custom_method FROM jsonb_array_elements(CASE
   WHEN jsonb_typeof(store.configuracion->'paymentDetails'->'customMethods')='array'
   THEN store.configuracion->'paymentDetails'->'customMethods' ELSE '[]'::jsonb END) m
  WHERE jsonb_typeof(m)='object' AND m->>'id'=p_pago->>'methodId' AND m->'enabled'='true'::jsonb
   AND length(btrim(COALESCE(m->>'name',''))) BETWEEN 2 AND 60
   AND length(btrim(COALESCE(m->>'instructions',''))) BETWEEN 1 AND 500
  LIMIT 1;
  IF custom_method IS NULL THEN RAISE EXCEPTION 'Payment method unavailable' USING ERRCODE='22023';END IF;
  payment_snapshot:=jsonb_build_object('method','custom','status','PENDING_VERIFICATION',
   'reference',payment_reference,'methodId',custom_method->>'id','name',btrim(custom_method->>'name'),
   'instructions',btrim(custom_method->>'instructions'));
 ELSE
  payment_recipient:=CASE payment_method WHEN 'mobile' THEN store.configuracion->'paymentDetails'->'mobilePayment'
   ELSE store.configuracion->'paymentDetails'->'bankTransfer' END;
  IF COALESCE((store.configuracion->'payments'->>(CASE payment_method WHEN 'mobile' THEN 'pago-movil' ELSE 'transferencia' END))::boolean,false)=false
   OR jsonb_typeof(payment_recipient)<>'object'
   OR length(COALESCE(payment_recipient->>'document',''))<4
   OR length(COALESCE(payment_recipient->>'bankCode',''))<3
   OR (payment_method='mobile' AND length(COALESCE(payment_recipient->>'phone',''))<7)
   OR (payment_method='transfer' AND length(COALESCE(payment_recipient->>'accountNumber',''))<8)
  THEN RAISE EXCEPTION 'Payment method unavailable' USING ERRCODE='22023';END IF;
  payment_snapshot:=jsonb_build_object('method',payment_method,'status','PENDING_VERIFICATION',
   'reference',payment_reference,'recipient',payment_recipient);
 END IF;
 SELECT * INTO node FROM operaciones.nodos WHERE tenant_id=tenant AND empresa_id=store.empresa_id
  AND id=store.nodo_id AND estado='ACTIVE' AND acepta_pedidos FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Store node unavailable' USING ERRCODE='42501';END IF;
 fingerprint:=encode(public.digest(jsonb_build_object('domain',lower(p_dominio),'items',p_items,
  'delivery',p_entrega,'delivery_method',p_metodo_entrega,'payment',p_pago)::text,'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
 SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF cached.actor_user_id<>actor OR cached.request_tenant_id<>tenant
   OR cached.operation<>'digital_sales.storefront.checkout' OR cached.request_fingerprint<>fingerprint THEN
   RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505';END IF;
  RETURN cached.response_payload;
 END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_items) item
  WHERE jsonb_typeof(item)<>'object' OR NOT(item ?& ARRAY['product_id','quantity'])
  OR (item->>'quantity')::numeric<=0 OR scale((item->>'quantity')::numeric)>6)
 THEN RAISE EXCEPTION 'Invalid checkout items' USING ERRCODE='22023';END IF;
 SELECT jsonb_agg(jsonb_build_object('product_id',p.id,'product_name',p.nombre,
   'quantity',requested.quantity,'unit_price',p.precio) ORDER BY p.id),
  sum(requested.quantity*p.precio)
 INTO order_items,subtotal_value
 FROM (SELECT (item->>'product_id')::uuid product_id,sum((item->>'quantity')::numeric) quantity
       FROM jsonb_array_elements(p_items) item GROUP BY (item->>'product_id')::uuid) requested
 JOIN catalogo.productos p ON p.tenant_id=tenant AND p.id=requested.product_id AND p.estado='ACTIVE'
 JOIN catalogo.inventarios i ON i.tenant_id=tenant AND i.empresa_id=store.empresa_id
  AND i.nodo_id=store.nodo_id AND i.producto_id=p.id AND i.ventas_habilitadas;
 IF order_items IS NULL OR jsonb_array_length(order_items)<>(SELECT count(DISTINCT item->>'product_id') FROM jsonb_array_elements(p_items) item)
 THEN RAISE EXCEPTION 'Product unavailable' USING ERRCODE='P0002';END IF;
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(p_idempotency_key,actor,'digital_sales.storefront.checkout',order_id,fingerprint,tenant);
 INSERT INTO catalogo.reservas_inventario(id,tenant_id,empresa_id,nodo_id,referencia_externa,idempotency_key,creado_por)
 VALUES(reservation_id,tenant,store.empresa_id,store.nodo_id,order_id::text,p_idempotency_key,actor);
 FOR line IN SELECT (item->>'product_id')::uuid product_id,(item->>'quantity')::numeric quantity
  FROM jsonb_array_elements(order_items) item ORDER BY item->>'product_id' LOOP
  SELECT * INTO inventory FROM catalogo.inventarios WHERE tenant_id=tenant AND empresa_id=store.empresa_id
   AND nodo_id=store.nodo_id AND producto_id=line.product_id FOR UPDATE;
  IF inventory.disponible<line.quantity THEN RAISE EXCEPTION 'Insufficient inventory' USING ERRCODE='23514';END IF;
  UPDATE catalogo.inventarios SET reservado=reservado+line.quantity,version=version+1,
   actualizado_por=actor,actualizado_en=transaction_timestamp()
  WHERE tenant_id=tenant AND empresa_id=store.empresa_id AND nodo_id=store.nodo_id AND producto_id=line.product_id;
  INSERT INTO catalogo.reserva_inventario_lineas VALUES(tenant,store.empresa_id,reservation_id,store.nodo_id,line.product_id,line.quantity);
  INSERT INTO catalogo.movimientos_inventario(tenant_id,empresa_id,nodo_id,producto_id,tipo,cantidad,anterior,nuevo,motivo,referencia,actor_id,correlation_id)
  VALUES(tenant,store.empresa_id,store.nodo_id,line.product_id,'RESERVE',line.quantity,inventory.reservado,
   inventory.reservado+line.quantity,'STOREFRONT_CHECKOUT',reservation_id::text,actor,correlation);
 END LOOP;
 currency_code:=COALESCE(NULLIF(store.configuracion->>'currency','')::char(3),'USD');
 INSERT INTO operaciones.pedidos(id,tenant_id,empresa_id,sucursal_id,cliente_id,numero,estado,moneda,subtotal,
  tarifa_entrega,cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,
  reserva_inventario_ref,idempotency_key,creado_por)
 SELECT order_id,tenant,store.empresa_id,store.nodo_id,customer,
  'ORD-'||upper(substr(replace(order_id::text,'-',''),1,12)),'PENDING',currency_code,subtotal_value,
  node.tarifa_entrega,jsonb_build_object('customer_id',customer,'name',t.nombre),p_entrega,
  payment_snapshot,'immediate',p_metodo_entrega,
  reservation_id::text,p_idempotency_key,actor FROM catalogo.terceros t WHERE t.tenant_id=tenant AND t.id=customer;
 INSERT INTO operaciones.pedido_lineas(tenant_id,empresa_id,pedido_id,posicion,producto_id,producto_nombre,cantidad,precio_unitario)
 SELECT tenant,store.empresa_id,order_id,ordinality,(item->>'product_id')::uuid,item->>'product_name',
  (item->>'quantity')::numeric,(item->>'unit_price')::numeric
 FROM jsonb_array_elements(order_items) WITH ORDINALITY source(item,ordinality);
 INSERT INTO operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,estado_nuevo,motivo,actor_id,correlation_id)
 VALUES(tenant,store.empresa_id,order_id,'PENDING','STOREFRONT_CHECKOUT',actor,correlation);
 SELECT jsonb_build_object('id',p.id,'number',p.numero,'status',p.estado,'currency',p.moneda,
  'subtotal',p.subtotal,'delivery_fee',p.tarifa_entrega,'total',p.total,'reservation_ref',reservation_id)
 INTO response FROM operaciones.pedidos p WHERE p.id=order_id;
 UPDATE plataforma.idempotency_keys SET response_payload=response WHERE idempotency_key=p_idempotency_key;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.4.2-ecommerce','pedido',order_id,'digital_sales.storefront.checkout',correlation,
  jsonb_build_object('empresa_id',store.empresa_id,'tienda_id',store.id,'reserva_id',reservation_id));
 RETURN response;
END $$;

REVOKE ALL ON FUNCTION ventas_digitales.checkout_crear(text,text,text,jsonb,jsonb,text,jsonb,varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ventas_digitales.checkout_crear(text,text,text,jsonb,jsonb,text,jsonb,varchar) TO mastererp_app;

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

CREATE OR REPLACE FUNCTION operaciones.pedido_confirmar_para_venta(p_empresa uuid,p_id uuid,p_version bigint,p_motivo text,p_detalle text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,operaciones,plataforma,auditoria,pg_temp AS $$
DECLARE tenant uuid:=plataforma.current_app_tenant_id(); actor uuid:=plataforma.current_app_user_id();
 pedido operaciones.pedidos%ROWTYPE; correlation uuid;
BEGIN
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'administracion.documento.venta.crear'
 OR plataforma.has_current_tenant_capability('erp.finance','administration.sales.write',p_empresa) IS NOT TRUE
 OR plataforma.has_current_tenant_capability('erp.operations','operations.orders.read',p_empresa) IS NOT TRUE
 THEN RAISE EXCEPTION 'Sale confirmation denied' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL OR p_motivo IS NULL OR length(btrim(p_motivo)) NOT BETWEEN 1 AND 80
 OR (p_detalle IS NOT NULL AND length(p_detalle)>500)
 THEN RAISE EXCEPTION 'Invalid sale confirmation' USING ERRCODE='22023'; END IF;
 SELECT * INTO pedido FROM operaciones.pedidos WHERE tenant_id=tenant AND empresa_id=p_empresa AND id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found' USING ERRCODE='P0002'; END IF;
 IF plataforma.has_current_tenant_capability('erp.finance','administration.sales.write',p_empresa,pedido.sucursal_id) IS NOT TRUE
 THEN RAISE EXCEPTION 'Sale branch denied' USING ERRCODE='42501'; END IF;
 IF pedido.version IS DISTINCT FROM p_version THEN RAISE EXCEPTION 'Stale order version' USING ERRCODE='40001'; END IF;
 IF pedido.estado<>'PENDING' THEN RAISE EXCEPTION 'Pending order required' USING ERRCODE='23514'; END IF;
 IF (pedido.pago_snapshot->>'method' IN ('cash','pos') AND pedido.pago_snapshot->>'status'='PENDING_COLLECTION'
 OR pedido.pago_snapshot->>'method' IN ('mobile','transfer','mobile_payment','bank_transfer','custom')
 AND pedido.pago_snapshot->>'status'='VALIDATED') IS NOT TRUE
 THEN RAISE EXCEPTION 'Payment not ready' USING ERRCODE='23514'; END IF;
 UPDATE operaciones.pedidos SET estado='CONFIRMED',version=version+1,actualizado_en=transaction_timestamp() WHERE id=p_id;
 INSERT INTO operaciones.pedido_eventos(tenant_id,empresa_id,pedido_id,estado_anterior,estado_nuevo,motivo,detalle,actor_id,correlation_id)
 VALUES(tenant,p_empresa,p_id,'PENDING','CONFIRMED',btrim(p_motivo),NULLIF(btrim(p_detalle),''),actor,correlation);
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.3.1-orders','pedido',p_id,'operations.orders.transition',correlation,
 jsonb_build_object('empresa_id',p_empresa,'estado_anterior','PENDING','estado_nuevo','CONFIRMED','resultado','succeeded'));
END $$;
REVOKE ALL ON FUNCTION operaciones.pedido_confirmar_para_venta(uuid,uuid,bigint,text,text) FROM PUBLIC,mastererp_app;
