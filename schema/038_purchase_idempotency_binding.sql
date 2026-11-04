-- Preserve the existing deferred document/idempotency contract; migration 037 remains unchanged.
CREATE OR REPLACE FUNCTION administracion.purchase_write(
 p_company uuid,p_kind text,p_id uuid,p_version bigint,p_key text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,catalogo,plataforma,organizacion,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id();
 operation text; cache_key text; fingerprint text; cached plataforma.idempotency_keys%ROWTYPE;
 target administracion.documentos%ROWTYPE; origin administracion.documentos%ROWTYPE;
 line jsonb; line_position integer:=0; quantity numeric; price numeric; amount numeric; total_amount numeric:=0;
 supplier uuid; source uuid; currency text; base_currency text; rate numeric; decimals integer; result jsonb; correlation uuid;
BEGIN
 IF p_kind IS NULL OR p_kind NOT IN ('solicitud_compra','orden_compra','factura_proveedor')
 OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR octet_length(p_payload::text)>60000
 OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k NOT IN
 ('fecha','numero','serie','proveedor_id','origen_id','moneda','tipo_cambio','cambio_fecha','cambio_fuente','lineas')) THEN
 RAISE EXCEPTION 'Invalid purchase input' USING ERRCODE='22023'; END IF;
 IF p_company IS NULL OR plataforma.has_current_tenant_capability('erp.finance','administration.purchases.read',p_company) IS NOT TRUE
 OR plataforma.has_current_tenant_capability('erp.finance','administration.purchases.write',p_company) IS NOT TRUE THEN
 RAISE EXCEPTION 'Purchase access denied' USING ERRCODE='42501'; END IF;
 operation:='administracion.documento.'||p_kind||CASE WHEN p_id IS NULL THEN '.crear' ELSE '.actualizar' END;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL OR current_setting('app.current_operation',true) IS DISTINCT FROM operation THEN
 RAISE EXCEPTION 'Purchase operation context denied' USING ERRCODE='42501'; END IF;
 IF p_id IS NULL THEN
  IF p_key IS NULL OR p_key !~ '^[A-Za-z0-9._:-]{1,128}$' THEN RAISE EXCEPTION 'Idempotency key required' USING ERRCODE='22023'; END IF;
  cache_key:=encode(sha256(convert_to(jsonb_build_array(actor,tenant,p_company,operation,p_key)::text,'UTF8')),'hex');
  fingerprint:=encode(sha256(convert_to(p_payload::text,'UTF8')),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(cache_key,0));
  SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=cache_key;
  IF FOUND THEN
   IF (cached.actor_user_id,cached.request_tenant_id,cached.operation,cached.request_fingerprint)
    IS DISTINCT FROM (actor,tenant,operation,fingerprint) OR cached.response_payload IS NULL THEN
    RAISE EXCEPTION 'Idempotency content conflict' USING ERRCODE='23505'; END IF;
   RETURN cached.response_payload||jsonb_build_object('replayed',true);
  END IF;
 END IF;
 -- One lock order for all three drafts; protects source links and concurrent edits.
 PERFORM 1 FROM organizacion.companies WHERE tenant_id=tenant AND id=p_company FOR UPDATE;
 SELECT base_currency_code INTO base_currency FROM organizacion.companies WHERE tenant_id=tenant AND id=p_company;
 supplier:=NULLIF(p_payload->>'proveedor_id','')::uuid; source:=NULLIF(p_payload->>'origen_id','')::uuid;
 currency:=p_payload->>'moneda'; rate:=(p_payload->>'tipo_cambio')::numeric;
 SELECT decimales INTO decimals FROM catalogo.monedas WHERE codigo=currency;
 IF decimals IS NULL OR rate IS NULL OR rate<=0 OR scale(rate)>12 OR (currency=base_currency AND rate<>1)
 OR NULLIF(p_payload->>'fecha','') IS NULL OR NULLIF(p_payload->>'cambio_fecha','') IS NULL
 OR length(btrim(COALESCE(p_payload->>'cambio_fuente',''))) NOT BETWEEN 1 AND 120
 OR length(COALESCE(p_payload->>'numero',''))>80 OR length(COALESCE(p_payload->>'serie',''))>40 THEN
 RAISE EXCEPTION 'Invalid purchase currency or reference' USING ERRCODE='22023'; END IF;
 IF supplier IS NULL OR NOT EXISTS(SELECT 1 FROM administracion.perfiles_tercero p
 JOIN catalogo.proveedores_catalogo s ON (s.tenant_id,s.tercero_id)=(p.tenant_id,p.tercero_id)
 WHERE p.tenant_id=tenant AND p.empresa_id=p_company AND p.tercero_id=supplier AND p.rol='proveedor' AND s.estado='ACTIVE') THEN
 RAISE EXCEPTION 'Supplier unavailable in company' USING ERRCODE='22023'; END IF;
 IF p_kind='solicitud_compra' AND source IS NOT NULL THEN RAISE EXCEPTION 'Request has no source' USING ERRCODE='22023'; END IF;
 IF p_kind<>'solicitud_compra' THEN
  SELECT * INTO origin FROM administracion.documentos WHERE tenant_id=tenant AND empresa_id=p_company AND id=source;
  IF NOT FOUND OR origin.origen_sistema IS DISTINCT FROM 'mastererp.purchase-draft.v1'
   OR origin.clase IS DISTINCT FROM (CASE p_kind WHEN 'orden_compra' THEN 'solicitud_compra' ELSE 'orden_compra' END)
   OR origin.tercero_id IS DISTINCT FROM supplier OR origin.moneda IS DISTINCT FROM currency THEN
   RAISE EXCEPTION 'Compatible purchase source required' USING ERRCODE='22023'; END IF;
  IF EXISTS(SELECT 1 FROM administracion.documentos d WHERE d.tenant_id=tenant AND d.empresa_id=p_company
   AND d.documento_origen_id=source AND d.clase=p_kind AND d.id IS DISTINCT FROM p_id) THEN
   RAISE EXCEPTION 'Source already used' USING ERRCODE='23505'; END IF;
 END IF;
 IF jsonb_typeof(p_payload->'lineas') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Lines required' USING ERRCODE='22023'; END IF;
 IF jsonb_array_length(p_payload->'lineas') NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid line count' USING ERRCODE='22023'; END IF;
 FOR line IN SELECT * FROM jsonb_array_elements(p_payload->'lineas') LOOP
  IF jsonb_typeof(line) IS DISTINCT FROM 'object' OR EXISTS(SELECT 1 FROM jsonb_object_keys(line) k WHERE k NOT IN ('descripcion','cantidad','precio_unitario'))
  OR length(btrim(COALESCE(line->>'descripcion',''))) NOT BETWEEN 1 AND 500
  OR COALESCE(line->>'cantidad','') !~ '^[0-9]+([.][0-9]{1,6})?$'
  OR COALESCE(line->>'precio_unitario','') !~ '^[0-9]+([.][0-9]{1,6})?$' THEN
  RAISE EXCEPTION 'Invalid purchase line' USING ERRCODE='22023'; END IF;
  quantity:=(line->>'cantidad')::numeric; price:=(line->>'precio_unitario')::numeric; amount:=trim_scale(quantity*price);
  IF quantity<=0 OR quantity>=1e18 OR price>=1e18 OR scale(amount)>6 OR amount<>round(amount,decimals) THEN
  RAISE EXCEPTION 'Line amount exceeds currency precision' USING ERRCODE='22023'; END IF;
  total_amount:=total_amount+amount;
 END LOOP;
 IF p_id IS NULL THEN
  INSERT INTO administracion.documentos(tenant_id,empresa_id,clase,tercero_id,rol_tercero,documento_origen_id,
   fecha,serie,numero,moneda,moneda_base,tipo_cambio,cambio_fecha,cambio_fuente,total,origen_sistema,referencia_externa,idempotency_key)
  VALUES(tenant,p_company,p_kind,supplier,'proveedor',source,(p_payload->>'fecha')::date,COALESCE(p_payload->>'serie',''),
   NULLIF(btrim(p_payload->>'numero'),''),currency,base_currency,rate,(p_payload->>'cambio_fecha')::date,
   p_payload->>'cambio_fuente',total_amount,'mastererp.purchase-draft.v1',cache_key,cache_key) RETURNING * INTO target;
 ELSE
  SELECT * INTO target FROM administracion.documentos WHERE tenant_id=tenant AND empresa_id=p_company AND id=p_id FOR UPDATE;
  IF NOT FOUND OR target.clase<>p_kind OR target.origen_sistema IS DISTINCT FROM 'mastererp.purchase-draft.v1' THEN
   RAISE EXCEPTION 'Purchase not found' USING ERRCODE='P0002'; END IF;
  IF p_version IS NULL OR target.version<>p_version THEN RAISE EXCEPTION 'Stale purchase version' USING ERRCODE='40001'; END IF;
  IF target.cerrado OR EXISTS(SELECT 1 FROM administracion.documentos WHERE tenant_id=tenant AND empresa_id=p_company AND documento_origen_id=p_id) THEN
   RAISE EXCEPTION 'Purchase has downstream document' USING ERRCODE='55000'; END IF;
  IF target.documento_origen_id IS DISTINCT FROM source THEN RAISE EXCEPTION 'Purchase source immutable' USING ERRCODE='22023'; END IF;
  UPDATE administracion.documentos SET tercero_id=supplier,fecha=(p_payload->>'fecha')::date,serie=COALESCE(p_payload->>'serie',''),
   numero=NULLIF(btrim(p_payload->>'numero'),''),moneda=currency,tipo_cambio=rate,cambio_fecha=(p_payload->>'cambio_fecha')::date,
   cambio_fuente=p_payload->>'cambio_fuente',total=total_amount,version=version+1 WHERE id=p_id RETURNING * INTO target;
  DELETE FROM administracion.detalles_documento WHERE tenant_id=tenant AND empresa_id=p_company AND documento_id=p_id;
 END IF;
 FOR line IN SELECT * FROM jsonb_array_elements(p_payload->'lineas') LOOP
  line_position:=line_position+1;
  INSERT INTO administracion.detalles_documento(tenant_id,empresa_id,documento_id,posicion,descripcion,cantidad,precio_unitario,subtotal)
  VALUES(tenant,p_company,target.id,line_position,line->>'descripcion',(line->>'cantidad')::numeric,
   (line->>'precio_unitario')::numeric,(line->>'cantidad')::numeric*(line->>'precio_unitario')::numeric);
 END LOOP;
 -- Existing deferred constraints are checked by the API transaction COMMIT.
 result:=administracion.purchase_read(p_company,p_kind,target.id)||jsonb_build_object('replayed',false);
 IF p_id IS NULL THEN
  INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id,response_payload)
  VALUES(cache_key,actor,operation,target.id,fingerprint,tenant,result);
 END IF;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.2.1-administration','documento',target.id,operation,correlation,jsonb_build_object('empresa_id',p_company,'resultado','succeeded'));
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION administracion.purchase_write(uuid,text,uuid,bigint,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION administracion.purchase_write(uuid,text,uuid,bigint,text,jsonb) TO mastererp_app;
