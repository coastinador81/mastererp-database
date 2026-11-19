-- Storefront node selection and commercial variant snapshots.
ALTER TABLE operaciones.pedido_lineas ADD COLUMN IF NOT EXISTS variante_snapshot jsonb;

CREATE OR REPLACE FUNCTION ventas_digitales.catalogo_publico(p_dominio text,p_limit integer,p_nodo uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventas_digitales,catalogo,operaciones,plataforma,pg_temp AS $$
DECLARE store ventas_digitales.tiendas%ROWTYPE; selected_node operaciones.nodos%ROWTYPE;
BEGIN
 IF p_limit NOT BETWEEN 1 AND 201 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023';END IF;
 SELECT * INTO store FROM ventas_digitales.tiendas WHERE tenant_id=plataforma.current_app_tenant_id() AND dominio=lower(p_dominio) AND estado='ACTIVE';
 IF NOT FOUND THEN RAISE EXCEPTION 'Store not found' USING ERRCODE='P0002';END IF;
 SELECT * INTO selected_node FROM operaciones.nodos WHERE tenant_id=store.tenant_id AND empresa_id=store.empresa_id AND id=COALESCE(p_nodo,store.nodo_id) AND estado='ACTIVE' AND acepta_pedidos;
 IF NOT FOUND THEN RAISE EXCEPTION 'Store node unavailable' USING ERRCODE='P0002';END IF;
 RETURN jsonb_build_object('store',jsonb_build_object('id',store.id,'name',store.nombre,'node_id',selected_node.id,'default_node_id',store.nodo_id,'branding',store.marca,'configuration',store.configuracion||jsonb_build_object('deliveryFee',selected_node.tarifa_entrega),'modules',store.modulos,
  'nodes',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',n.id,'name',b.name) ORDER BY b.name),'[]')
   FROM operaciones.nodos n JOIN organizacion.branches b
    ON (b.tenant_id,b.company_id,b.id)=(n.tenant_id,n.empresa_id,n.id)
   WHERE n.tenant_id=store.tenant_id AND n.empresa_id=store.empresa_id AND n.estado='ACTIVE' AND n.acepta_pedidos)),
  'categories',(SELECT COALESCE(jsonb_agg(jsonb_build_object('slug',slug,'name',nombre,'image_url',imagen_url) ORDER BY orden,nombre),'[]') FROM catalogo.categorias WHERE tenant_id=store.tenant_id AND estado='ACTIVE'),
  'products',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',p.id,'name',p.nombre,'description',p.descripcion,'price',p.precio,'image_url',p.imagen_url,'category_ref',p.categoria_ref,'brand_ref',p.marca_ref,'attributes',p.atributos,'available',i.disponible) ORDER BY p.nombre),'[]') FROM catalogo.productos p JOIN catalogo.inventarios i ON i.tenant_id=p.tenant_id AND i.producto_id=p.id WHERE p.tenant_id=store.tenant_id AND p.estado='ACTIVE' AND i.empresa_id=store.empresa_id AND i.nodo_id=selected_node.id AND i.ventas_habilitadas AND i.disponible>0 LIMIT p_limit));
END $$;
REVOKE ALL ON FUNCTION ventas_digitales.catalogo_publico(text,integer,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ventas_digitales.catalogo_publico(text,integer,uuid) TO mastererp_app;

CREATE OR REPLACE FUNCTION ventas_digitales.checkout_crear(
 p_issuer text,p_subject text,p_dominio text,p_items jsonb,p_entrega jsonb,
 p_metodo_entrega text,p_pago jsonb,p_idempotency_key varchar,p_nodo uuid)
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
 OR jsonb_typeof(p_entrega)<>'object' OR length(COALESCE(btrim(p_entrega->>'address'),'')) NOT BETWEEN 5 AND 500
 OR jsonb_typeof(p_entrega->'latitude') IS DISTINCT FROM 'number' OR (p_entrega->>'latitude')::numeric NOT BETWEEN -90 AND 90
 OR jsonb_typeof(p_entrega->'longitude') IS DISTINCT FROM 'number' OR (p_entrega->>'longitude')::numeric NOT BETWEEN -180 AND 180
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
  AND id=COALESCE(p_nodo,store.nodo_id) AND estado='ACTIVE' AND acepta_pedidos FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Store node unavailable' USING ERRCODE='42501';END IF;
 fingerprint:=encode(public.digest(jsonb_build_object('domain',lower(p_dominio),'node_id',node.id,'items',p_items,
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
   'quantity',requested.quantity,'unit_price',p.precio+COALESCE((variant->>'price_delta')::numeric,0),
   'variant_key',requested.variant_key,'variant',variant) ORDER BY p.id,requested.variant_key),
  sum(requested.quantity*(p.precio+COALESCE((variant->>'price_delta')::numeric,0)))
 INTO order_items,subtotal_value
 FROM (SELECT (item->>'product_id')::uuid product_id,NULLIF(item->>'variant_key','') variant_key,
       sum((item->>'quantity')::numeric) quantity FROM jsonb_array_elements(p_items) item
       GROUP BY (item->>'product_id')::uuid,NULLIF(item->>'variant_key','')) requested
 JOIN catalogo.productos p ON p.tenant_id=tenant AND p.id=requested.product_id AND p.estado='ACTIVE'
 JOIN catalogo.inventarios i ON i.tenant_id=tenant AND i.empresa_id=store.empresa_id
  AND i.nodo_id=node.id AND i.producto_id=p.id AND i.ventas_habilitadas
 LEFT JOIN LATERAL(SELECT value variant FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p.atributos->'_catalog'->'variants')='array' THEN p.atributos->'_catalog'->'variants' ELSE '[]'::jsonb END)
   WHERE value->>'key'=requested.variant_key AND COALESCE((value->>'active')::boolean,true) LIMIT 1)v ON true
 WHERE (jsonb_array_length(CASE WHEN jsonb_typeof(p.atributos->'_catalog'->'variants')='array' THEN p.atributos->'_catalog'->'variants' ELSE '[]'::jsonb END)=0 AND requested.variant_key IS NULL)
    OR (requested.variant_key IS NOT NULL AND variant IS NOT NULL);
 IF order_items IS NULL OR jsonb_array_length(order_items)<>(SELECT count(*) FROM(SELECT item->>'product_id',NULLIF(item->>'variant_key','') FROM jsonb_array_elements(p_items)item GROUP BY 1,2)q)
 THEN RAISE EXCEPTION 'Product unavailable' USING ERRCODE='P0002';END IF;
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id)
 VALUES(p_idempotency_key,actor,'digital_sales.storefront.checkout',order_id,fingerprint,tenant);
 INSERT INTO catalogo.reservas_inventario(id,tenant_id,empresa_id,nodo_id,referencia_externa,idempotency_key,creado_por)
 VALUES(reservation_id,tenant,store.empresa_id,node.id,order_id::text,p_idempotency_key,actor);
 FOR line IN SELECT (item->>'product_id')::uuid product_id,sum((item->>'quantity')::numeric) quantity
  FROM jsonb_array_elements(order_items) item GROUP BY (item->>'product_id')::uuid ORDER BY product_id LOOP
  SELECT * INTO inventory FROM catalogo.inventarios WHERE tenant_id=tenant AND empresa_id=store.empresa_id
   AND nodo_id=node.id AND producto_id=line.product_id FOR UPDATE;
  IF inventory.disponible<line.quantity THEN RAISE EXCEPTION 'Insufficient inventory' USING ERRCODE='23514';END IF;
  UPDATE catalogo.inventarios SET reservado=reservado+line.quantity,version=version+1,
   actualizado_por=actor,actualizado_en=transaction_timestamp()
  WHERE tenant_id=tenant AND empresa_id=store.empresa_id AND nodo_id=node.id AND producto_id=line.product_id;
  INSERT INTO catalogo.reserva_inventario_lineas VALUES(tenant,store.empresa_id,reservation_id,node.id,line.product_id,line.quantity);
  INSERT INTO catalogo.movimientos_inventario(tenant_id,empresa_id,nodo_id,producto_id,tipo,cantidad,anterior,nuevo,motivo,referencia,actor_id,correlation_id)
  VALUES(tenant,store.empresa_id,node.id,line.product_id,'RESERVE',line.quantity,inventory.reservado,
   inventory.reservado+line.quantity,'STOREFRONT_CHECKOUT',reservation_id::text,actor,correlation);
 END LOOP;
 currency_code:=COALESCE(NULLIF(store.configuracion->>'currency','')::char(3),'USD');
 INSERT INTO operaciones.pedidos(id,tenant_id,empresa_id,sucursal_id,cliente_id,numero,estado,moneda,subtotal,
  tarifa_entrega,cliente_snapshot,entrega_snapshot,pago_snapshot,ventana_entrega_ref,metodo_entrega,
  reserva_inventario_ref,idempotency_key,creado_por)
 SELECT order_id,tenant,store.empresa_id,node.id,customer,
  'ORD-'||upper(substr(replace(order_id::text,'-',''),1,12)),'PENDING',currency_code,subtotal_value,
  node.tarifa_entrega,jsonb_build_object('customer_id',customer,'name',t.nombre,'phone',profile.telefono),p_entrega,
  payment_snapshot,'immediate',p_metodo_entrega,
  reservation_id::text,p_idempotency_key,actor FROM catalogo.terceros t
  LEFT JOIN ventas_digitales.cliente_perfiles profile
   ON (profile.tenant_id,profile.empresa_id,profile.cliente_id)=(tenant,store.empresa_id,t.id)
  WHERE t.tenant_id=tenant AND t.id=customer;
 INSERT INTO operaciones.pedido_lineas(tenant_id,empresa_id,pedido_id,posicion,producto_id,producto_nombre,cantidad,precio_unitario,variante_snapshot)
 SELECT tenant,store.empresa_id,order_id,ordinality,(item->>'product_id')::uuid,item->>'product_name',
  (item->>'quantity')::numeric,(item->>'unit_price')::numeric,item->'variant'
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

REVOKE ALL ON FUNCTION ventas_digitales.checkout_crear(text,text,text,jsonb,jsonb,text,jsonb,varchar,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ventas_digitales.checkout_crear(text,text,text,jsonb,jsonb,text,jsonb,varchar,uuid) TO mastererp_app;
