-- Transactional Storefront checkout. Identity, scope and prices are resolved server-side.
CREATE OR REPLACE FUNCTION ventas_digitales.checkout_crear(
 p_issuer text,p_subject text,p_dominio text,p_items jsonb,p_entrega jsonb,
 p_metodo_entrega text,p_metodo_pago text,p_idempotency_key varchar)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventas_digitales,catalogo,operaciones,plataforma,auditoria,pg_temp AS $$
DECLARE
 tenant uuid:=plataforma.current_app_tenant_id(); actor uuid; customer uuid;
 store ventas_digitales.tiendas%ROWTYPE; node operaciones.nodos%ROWTYPE;
 cached plataforma.idempotency_keys%ROWTYPE; fingerprint text; correlation uuid;
 reservation_id uuid:=gen_random_uuid(); order_id uuid:=gen_random_uuid(); line record;
 inventory catalogo.inventarios%ROWTYPE; order_items jsonb; subtotal_value administracion.importe;
 currency_code char(3); response jsonb;
BEGIN
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'digital_sales.storefront.checkout'
 OR p_issuer!~'^https://' OR length(p_subject) NOT BETWEEN 1 AND 255
 OR p_dominio IS NULL OR jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)=0
 OR jsonb_typeof(p_entrega)<>'object' OR length(COALESCE(btrim(p_entrega->>'address'),'')) NOT BETWEEN 1 AND 300
 OR p_metodo_entrega<>'realtime' OR p_metodo_pago<>'cash'
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
 SELECT * INTO node FROM operaciones.nodos WHERE tenant_id=tenant AND empresa_id=store.empresa_id
  AND id=store.nodo_id AND estado='ACTIVE' AND acepta_pedidos FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Store node unavailable' USING ERRCODE='42501';END IF;
 fingerprint:=encode(public.digest(jsonb_build_object('domain',lower(p_dominio),'items',p_items,
  'delivery',p_entrega,'delivery_method',p_metodo_entrega,'payment_method',p_metodo_pago)::text,'sha256'),'hex');
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
  jsonb_build_object('method','cash','status','PENDING_COLLECTION'),'immediate',p_metodo_entrega,
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

REVOKE ALL ON FUNCTION ventas_digitales.checkout_crear(text,text,text,jsonb,jsonb,text,text,varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ventas_digitales.checkout_crear(text,text,text,jsonb,jsonb,text,text,varchar) TO mastererp_app;
