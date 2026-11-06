-- Common internal party code. No backfill, triggers, new grants or product code changes.
-- Reviewed entrypoints: administrative v1/v2; Catalog create initializes both;
-- Catalog update cannot change code and already locks supplier -> master.
-- Existing SECURITY DEFINER authorization and signatures are retained below.
CREATE OR REPLACE FUNCTION administracion.party_write(
 p_company uuid,p_role text,p_action text,p_id uuid,p_code text,p_name text,
 p_version bigint,p_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,catalogo,plataforma,organizacion,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id();
 operation text; cache_key text; fingerprint text; cached plataforma.idempotency_keys%ROWTYPE;
 third catalogo.terceros%ROWTYPE; result jsonb; correlation uuid;
BEGIN
 IF p_company IS NULL OR p_role IS NULL OR p_role NOT IN ('cliente','proveedor')
 OR p_action IS NULL OR p_action NOT IN ('create','update') THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.finance','administration.parties.write',p_company) IS NOT TRUE
 OR plataforma.has_current_tenant_capability('erp.finance','administration.parties.read',p_company) IS NOT TRUE THEN
  RAISE EXCEPTION 'Party access denied' USING ERRCODE='42501'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL THEN RAISE EXCEPTION 'Correlation required' USING ERRCODE='22023'; END IF;
 operation:='administration.'||p_role||'.'||p_action;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM operation THEN
  RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 IF p_action='create' THEN
  IF p_key IS NULL OR length(p_key) NOT BETWEEN 1 AND 128 OR p_key !~ '^[A-Za-z0-9._:-]+$' THEN
   RAISE EXCEPTION 'Idempotency key required' USING ERRCODE='22023'; END IF;
  cache_key:=encode(sha256(convert_to(jsonb_build_array(actor,tenant,operation,p_key)::text,'UTF8')),'hex');
  fingerprint:=encode(sha256(convert_to(jsonb_build_array(actor,tenant,p_company,p_role,p_action,p_id,p_code,p_name)::text,'UTF8')),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(cache_key,0));
  SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=cache_key;
  IF FOUND THEN
   IF (cached.actor_user_id,cached.request_tenant_id,cached.operation,cached.request_fingerprint)
    IS DISTINCT FROM (actor,tenant,operation,fingerprint) THEN
    RAISE EXCEPTION 'Idempotency content conflict' USING ERRCODE='23505'; END IF;
   IF cached.response_payload IS NULL THEN RAISE EXCEPTION 'Incomplete idempotency record' USING ERRCODE='23505'; END IF;
   RETURN cached.response_payload||jsonb_build_object('replayed',true);
  END IF;
 END IF;
 -- Same tenant-wide canonical master may be referenced by several companies.
 PERFORM pg_advisory_xact_lock(hashtextextended(tenant::text||':party-master',0));
 IF p_id IS NOT NULL THEN PERFORM 1 FROM catalogo.proveedores_catalogo WHERE tenant_id=tenant AND tercero_id=p_id FOR UPDATE; END IF;
 IF p_action='create' AND p_id IS NULL THEN
  IF p_code IS NULL OR length(btrim(p_code)) NOT BETWEEN 1 AND 80 OR p_code<>btrim(p_code)
   OR p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 200 OR p_name<>btrim(p_name) THEN
   RAISE EXCEPTION 'Code/name required' USING ERRCODE='22023'; END IF;
  INSERT INTO catalogo.terceros(tenant_id,codigo,nombre) VALUES(tenant,p_code,p_name) RETURNING * INTO third;
 ELSE
  SELECT * INTO third FROM catalogo.terceros WHERE id=p_id AND tenant_id=tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Party not found' USING ERRCODE='P0002'; END IF;
  IF p_action='create' AND (p_code IS NOT NULL OR p_name IS NOT NULL) THEN
   RAISE EXCEPTION 'Reference existing party by ID only' USING ERRCODE='22023'; END IF;
 END IF;
 IF p_action='update' THEN
  IF NOT EXISTS(SELECT 1 FROM administracion.perfiles_tercero
   WHERE tenant_id=tenant AND empresa_id=p_company AND tercero_id=p_id AND rol=p_role) THEN
   RAISE EXCEPTION 'Party profile not found' USING ERRCODE='P0002'; END IF;
  IF p_version IS NULL OR third.version<>p_version THEN
   RAISE EXCEPTION 'Stale party version' USING ERRCODE='40001'; END IF;
  IF p_code IS NULL OR length(btrim(p_code)) NOT BETWEEN 1 AND 80 OR p_code<>btrim(p_code)
   OR p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 200 OR p_name<>btrim(p_name) THEN
   RAISE EXCEPTION 'Code/name required' USING ERRCODE='22023'; END IF;
  IF EXISTS(SELECT 1 FROM administracion.perfiles_tercero p WHERE p.tenant_id=tenant AND p.tercero_id=p_id
   AND plataforma.has_current_tenant_capability('erp.finance','administration.parties.write',p.empresa_id) IS NOT TRUE) THEN
   RAISE EXCEPTION 'Shared master scope denied' USING ERRCODE='42501'; END IF;
  IF third.codigo IS DISTINCT FROM p_code THEN
   IF EXISTS(SELECT 1 FROM catalogo.proveedores_catalogo
    WHERE tenant_id=tenant AND tercero_id=third.id AND codigo IS DISTINCT FROM third.codigo) THEN
    RAISE EXCEPTION 'Supplier code discrepancy requires explicit reconciliation' USING ERRCODE='23505';
   END IF;
   UPDATE catalogo.proveedores_catalogo SET codigo=p_code,version=version+1,
    actualizado_en=transaction_timestamp() WHERE tenant_id=tenant AND tercero_id=third.id;
  END IF;
  UPDATE catalogo.terceros SET codigo=p_code,nombre=p_name,version=version+1
   WHERE id=p_id AND tenant_id=tenant RETURNING * INTO third;
 ELSE
  INSERT INTO catalogo.roles_tercero(tenant_id,tercero_id,rol) VALUES(tenant,third.id,p_role) ON CONFLICT DO NOTHING;
  INSERT INTO administracion.perfiles_tercero(tenant_id,empresa_id,tercero_id,rol)
   VALUES(tenant,p_company,third.id,p_role);
 END IF;
 result:=administracion.parties_read(p_company,p_role,third.id)||jsonb_build_object('replayed',false);
 IF p_action='create' THEN
  INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id,response_payload)
   VALUES(cache_key,actor,operation,third.id,fingerprint,tenant,result);
 END IF;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.2.1-administration','tercero',third.id,operation,correlation,
  jsonb_build_object('empresa_id',p_company,'resultado','succeeded'));
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION administracion.party_write_v2(
 p_company uuid,p_role text,p_action text,p_id uuid,p_code text,p_name text,
 p_version bigint,p_key text DEFAULT NULL,p_details jsonb DEFAULT '{}'::jsonb,p_profile_version bigint DEFAULT NULL,p_catalog_version bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,catalogo,plataforma,organizacion,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id();
 operation text; cache_key text; fingerprint text; cached plataforma.idempotency_keys%ROWTYPE;
 third catalogo.terceros%ROWTYPE; result jsonb; correlation uuid;
 supplier catalogo.proveedores_catalogo%ROWTYPE; supplier_existed boolean; code_changed boolean:=false;
 profile administracion.perfiles_tercero%ROWTYPE; terms jsonb; condition uuid; edition integer; condition_code text;
BEGIN
 IF p_company IS NULL OR p_role IS NULL OR p_role NOT IN ('cliente','proveedor')
 OR p_action IS NULL OR p_action NOT IN ('create','update') THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.finance','administration.parties.write',p_company) IS NOT TRUE
 OR plataforma.has_current_tenant_capability('erp.finance','administration.parties.read',p_company) IS NOT TRUE THEN
  RAISE EXCEPTION 'Party access denied' USING ERRCODE='42501'; END IF;
 IF p_role<>'proveedor' AND p_details<>'{}'::jsonb THEN RAISE EXCEPTION 'Supplier extension is role-specific' USING ERRCODE='22023'; END IF;
 IF administracion.valid_party_extension(p_details) IS NOT TRUE THEN RAISE EXCEPTION 'Invalid party details' USING ERRCODE='22023'; END IF;
 IF p_action='create' AND p_id IS NOT NULL AND (p_details ? 'datos_generales' OR p_details ? 'contactos') THEN RAISE EXCEPTION 'Existing master details require update' USING ERRCODE='22023'; END IF;
 correlation:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;
 IF correlation IS NULL THEN RAISE EXCEPTION 'Correlation required' USING ERRCODE='22023'; END IF;
 operation:='administration.'||p_role||'.'||p_action;
 IF NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM operation THEN
  RAISE EXCEPTION 'Operation context mismatch' USING ERRCODE='42501'; END IF;
 IF p_action='create' THEN
  IF p_key IS NULL OR length(p_key) NOT BETWEEN 1 AND 128 OR p_key !~ '^[A-Za-z0-9._:-]+$' THEN
   RAISE EXCEPTION 'Idempotency key required' USING ERRCODE='22023'; END IF;
  cache_key:=encode(sha256(convert_to(jsonb_build_array(actor,tenant,operation,p_key)::text,'UTF8')),'hex');
  fingerprint:=encode(sha256(convert_to(jsonb_build_array(actor,tenant,p_company,p_role,p_action,p_id,p_code,p_name)::text,'UTF8')),'hex');
  IF p_details<>'{}'::jsonb THEN fingerprint:=encode(sha256(convert_to(jsonb_build_array(fingerprint,p_details)::text,'UTF8')),'hex'); END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(cache_key,0));
  SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=cache_key;
  IF FOUND THEN
   IF (cached.actor_user_id,cached.request_tenant_id,cached.operation,cached.request_fingerprint)
    IS DISTINCT FROM (actor,tenant,operation,fingerprint) THEN
    RAISE EXCEPTION 'Idempotency content conflict' USING ERRCODE='23505'; END IF;
   IF cached.response_payload IS NULL THEN RAISE EXCEPTION 'Incomplete idempotency record' USING ERRCODE='23505'; END IF;
   RETURN cached.response_payload||jsonb_build_object('replayed',true);
  END IF;
 END IF;
 -- Same tenant-wide canonical master may be referenced by several companies.
 PERFORM pg_advisory_xact_lock(hashtextextended(tenant::text||':party-master',0));
 -- Match the existing Catalog command's supplier -> master lock order.
 IF p_id IS NOT NULL THEN PERFORM 1 FROM catalogo.proveedores_catalogo WHERE tenant_id=tenant AND tercero_id=p_id FOR UPDATE; END IF;
 IF p_action='create' AND p_id IS NULL THEN
  IF p_code IS NULL OR length(btrim(p_code)) NOT BETWEEN 1 AND 80 OR p_code<>btrim(p_code)
   OR p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 200 OR p_name<>btrim(p_name) THEN
   RAISE EXCEPTION 'Code/name required' USING ERRCODE='22023'; END IF;
  INSERT INTO catalogo.terceros(tenant_id,codigo,nombre) VALUES(tenant,p_code,p_name) RETURNING * INTO third;
 ELSE
  SELECT * INTO third FROM catalogo.terceros WHERE id=p_id AND tenant_id=tenant FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Party not found' USING ERRCODE='P0002'; END IF;
  IF p_action='create' AND (p_code IS NOT NULL OR p_name IS NOT NULL) THEN
   RAISE EXCEPTION 'Reference existing party by ID only' USING ERRCODE='22023'; END IF;
 END IF;
 IF p_action='update' THEN
  IF NOT EXISTS(SELECT 1 FROM administracion.perfiles_tercero
   WHERE tenant_id=tenant AND empresa_id=p_company AND tercero_id=p_id AND rol=p_role) THEN
   RAISE EXCEPTION 'Party profile not found' USING ERRCODE='P0002'; END IF;
  IF p_version IS NULL OR third.version<>p_version THEN
   RAISE EXCEPTION 'Stale party version' USING ERRCODE='40001'; END IF;
  IF p_code IS NULL OR length(btrim(p_code)) NOT BETWEEN 1 AND 80 OR p_code<>btrim(p_code)
   OR p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 200 OR p_name<>btrim(p_name) THEN
   RAISE EXCEPTION 'Code/name required' USING ERRCODE='22023'; END IF;
  IF EXISTS(SELECT 1 FROM administracion.perfiles_tercero p WHERE p.tenant_id=tenant AND p.tercero_id=p_id
   AND plataforma.has_current_tenant_capability('erp.finance','administration.parties.write',p.empresa_id) IS NOT TRUE) THEN
   RAISE EXCEPTION 'Shared master scope denied' USING ERRCODE='42501'; END IF;
  IF third.codigo IS DISTINCT FROM p_code THEN
   IF EXISTS(SELECT 1 FROM catalogo.proveedores_catalogo
    WHERE tenant_id=tenant AND tercero_id=third.id AND codigo IS DISTINCT FROM third.codigo) THEN
    RAISE EXCEPTION 'Supplier code discrepancy requires explicit reconciliation' USING ERRCODE='23505';
   END IF;
   code_changed:=true;
   IF p_role<>'proveedor' OR NOT (p_details ? 'datos_generales' OR p_details ? 'contactos') THEN
   UPDATE catalogo.proveedores_catalogo SET codigo=p_code,version=version+1,
    actualizado_en=transaction_timestamp() WHERE tenant_id=tenant AND tercero_id=third.id;
   END IF;
  END IF;
  UPDATE catalogo.terceros SET codigo=p_code,nombre=p_name,version=version+1
   WHERE id=p_id AND tenant_id=tenant RETURNING * INTO third;
 ELSE
  INSERT INTO catalogo.roles_tercero(tenant_id,tercero_id,rol) VALUES(tenant,third.id,p_role) ON CONFLICT DO NOTHING;
  INSERT INTO administracion.perfiles_tercero(tenant_id,empresa_id,tercero_id,rol)
   VALUES(tenant,p_company,third.id,p_role);
 END IF;
 -- Commands retain the tenant-wide serialization and shared-master authorization above.
 IF p_role='proveedor' THEN
  SELECT * INTO supplier FROM catalogo.proveedores_catalogo WHERE tenant_id=tenant AND tercero_id=third.id FOR UPDATE;
  supplier_existed:=FOUND;
  IF p_action='update' AND (p_details ? 'datos_generales' OR p_details ? 'contactos')
   AND (p_catalog_version IS NULL OR p_catalog_version<>(CASE WHEN supplier_existed THEN supplier.version ELSE 0 END)) THEN
   RAISE EXCEPTION 'Stale catalog supplier version' USING ERRCODE='40001'; END IF;
  IF NOT supplier_existed THEN
   INSERT INTO catalogo.proveedores_catalogo(tenant_id,tercero_id,codigo,creado_por)
    VALUES(tenant,third.id,third.codigo,actor) RETURNING * INTO supplier;
  END IF;
  IF p_details ? 'datos_generales' OR p_details ? 'contactos' THEN
   UPDATE catalogo.proveedores_catalogo SET codigo=CASE WHEN code_changed THEN third.codigo ELSE codigo END,contacto=jsonb_strip_nulls(contacto||COALESCE(p_details->'datos_generales','{}'::jsonb))||
    CASE WHEN p_details ? 'contactos' THEN jsonb_build_object('personas',p_details->'contactos') ELSE '{}'::jsonb END,
    version=version+1,actualizado_en=transaction_timestamp() WHERE tenant_id=tenant AND tercero_id=third.id;
  END IF;
 END IF;
 IF p_details ? 'condiciones' THEN
  SELECT * INTO profile FROM administracion.perfiles_tercero WHERE tenant_id=tenant AND empresa_id=p_company AND tercero_id=third.id AND rol=p_role FOR UPDATE;
  IF p_action='update' AND (p_profile_version IS NULL OR profile.version<>p_profile_version) THEN
   RAISE EXCEPTION 'Stale profile version' USING ERRCODE='40001'; END IF;
  terms:=p_details->'condiciones'; condition:=NULL;
  -- Revisions reuse existing commercial-condition entities; never overwrite a condition shared elsewhere.
  IF NULLIF(terms->>'plazo_pago_dias','') IS NOT NULL OR NULLIF(terms->>'descuento_pronto_pago','') IS NOT NULL THEN
   condition_code:='PARTY-'||p_role||'-'||third.id::text;
   SELECT COALESCE(max(edicion),0)+1 INTO edition FROM administracion.condiciones_comerciales
    WHERE tenant_id=tenant AND empresa_id=p_company AND codigo=condition_code;
   INSERT INTO administracion.condiciones_comerciales(tenant_id,empresa_id,codigo,edicion,descripcion,dias_plazo)
    VALUES(tenant,p_company,condition_code,edition,'Condiciones de tercero',NULLIF(terms->>'plazo_pago_dias','')::integer) RETURNING id INTO condition;
   IF NULLIF(terms->>'descuento_pronto_pago','') IS NOT NULL THEN
    INSERT INTO administracion.descuentos_pronto_pago(tenant_id,empresa_id,condicion_id,hasta_dias,porcentaje)
     VALUES(tenant,p_company,condition,(terms->>'plazo_pronto_pago_dias')::integer,(terms->>'descuento_pronto_pago')::numeric);
   END IF;
  END IF;
  UPDATE administracion.perfiles_tercero SET condicion_id=condition,
   datos_comerciales=terms-'plazo_pago_dias'-'descuento_pronto_pago'-'plazo_pronto_pago_dias',
   version=version+1 WHERE id=profile.id AND tenant_id=tenant AND empresa_id=p_company;
 END IF;
 result:=administracion.parties_read_v2(p_company,p_role,third.id)||jsonb_build_object('replayed',false);
 IF p_action='create' THEN
  INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id,response_payload)
   VALUES(cache_key,actor,operation,third.id,fingerprint,tenant,result);
 END IF;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(tenant,actor,'2.2.1-administration','tercero',third.id,operation,correlation,
  jsonb_build_object('empresa_id',p_company,'resultado','succeeded'));
 RETURN result;
END $$;
