-- Common administrative identity/contact approved for customer and supplier roles.
-- No backfill: legacy Catalog data remains readable until explicitly edited.
ALTER TABLE catalogo.terceros ADD COLUMN IF NOT EXISTS datos_administrativos jsonb;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='catalogo.terceros'::regclass AND conname='tercero_datos_administrativos_object') THEN
  ALTER TABLE catalogo.terceros ADD CONSTRAINT tercero_datos_administrativos_object CHECK(datos_administrativos IS NULL OR jsonb_typeof(datos_administrativos)='object');
 END IF;
END $$;
CREATE OR REPLACE FUNCTION catalogo.normalizar_contacto_administrativo(p jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
 SELECT CASE WHEN p ? 'telefono' THEN p||jsonb_build_object('phone',p->'telefono') WHEN p ? 'phone' THEN p||jsonb_build_object('telefono',p->'phone') ELSE p END
$$;
REVOKE ALL ON FUNCTION catalogo.normalizar_contacto_administrativo(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION administracion.parties_read_v2(
 p_company uuid,p_role text,p_id uuid DEFAULT NULL,p_limit integer DEFAULT 25,p_after uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,catalogo,plataforma,organizacion,pg_temp AS $$
DECLARE result jsonb;
BEGIN
 IF p_company IS NULL OR p_role IS NULL OR p_role NOT IN ('cliente','proveedor')
 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 101 THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.finance','administration.parties.read',p_company) IS NOT TRUE THEN
  RAISE EXCEPTION 'Party access denied' USING ERRCODE='42501'; END IF;
 SELECT COALESCE(jsonb_agg(item ORDER BY id),'[]') INTO result FROM (
 SELECT t.id,jsonb_build_object('id',t.id,'profile_id',p.id,'company_id',p.empresa_id,
  'codigo',t.codigo,'nombre',t.nombre,'version',t.version,'profile_version',p.version,
  'datos_generales',COALESCE((SELECT jsonb_object_agg(k,v) FROM jsonb_each(COALESCE(t.datos_administrativos,s.contacto,'{}'::jsonb)) e(k,v) WHERE k IN ('nombre_comercial','tipo_persona','pais_fiscal','tipo_identificacion','numero_identificacion','direccion','direccion_complementaria','ciudad','municipio','region','codigo_postal','pais','email','telefono','telefono_alterno','sitio_web','observaciones')),'{}'::jsonb),
  'contactos',CASE WHEN jsonb_typeof(COALESCE(t.datos_administrativos,s.contacto)->'personas')='array' THEN COALESCE(t.datos_administrativos,s.contacto)->'personas' ELSE '[]'::jsonb END,'catalog_version',COALESCE(s.version,0),'catalog_status',s.estado,
  'condiciones',COALESCE(p.datos_comerciales,'{}'::jsonb)||jsonb_build_object(
    'plazo_pago_dias',COALESCE((SELECT c.dias_plazo::text FROM administracion.condiciones_comerciales c WHERE c.id=p.condicion_id AND c.tenant_id=p.tenant_id AND c.empresa_id=p.empresa_id),''),
    'descuento_pronto_pago',COALESCE((SELECT d.porcentaje::text FROM administracion.descuentos_pronto_pago d WHERE d.condicion_id=p.condicion_id AND d.tenant_id=p.tenant_id AND d.empresa_id=p.empresa_id LIMIT 1),''),
    'plazo_pronto_pago_dias',COALESCE((SELECT d.hasta_dias::text FROM administracion.descuentos_pronto_pago d WHERE d.condicion_id=p.condicion_id AND d.tenant_id=p.tenant_id AND d.empresa_id=p.empresa_id LIMIT 1),'')),
  'origen',CASE WHEN EXISTS(SELECT 1 FROM ventas_digitales.cliente_identidades ci WHERE ci.tenant_id=p.tenant_id AND ci.empresa_id=p.empresa_id AND ci.cliente_id=t.id) THEN 'ecommerce' ELSE 'sin_canal_identificado' END,
  'contacto_ecommerce',CASE WHEN p_role='cliente' THEN (SELECT jsonb_build_object('telefono',ec.telefono,'email',u.email) FROM ventas_digitales.cliente_identidades ci JOIN plataforma.users u ON u.id=ci.user_id LEFT JOIN ventas_digitales.cliente_perfiles ec ON (ec.tenant_id,ec.empresa_id,ec.cliente_id)=(ci.tenant_id,ci.empresa_id,ci.cliente_id) WHERE (ci.tenant_id,ci.empresa_id,ci.cliente_id)=(p.tenant_id,p.empresa_id,t.id)) ELSE NULL END,
  'roles',(SELECT jsonb_agg(x.rol ORDER BY x.rol) FROM administracion.perfiles_tercero x
   WHERE x.tenant_id=p.tenant_id AND x.empresa_id=p.empresa_id AND x.tercero_id=t.id)) item
 FROM catalogo.terceros t JOIN administracion.perfiles_tercero p
 ON (p.tenant_id,p.tercero_id)=(t.tenant_id,t.id)
 LEFT JOIN catalogo.proveedores_catalogo s ON (s.tenant_id,s.tercero_id)=(t.tenant_id,t.id)
 WHERE t.tenant_id=plataforma.current_app_tenant_id() AND p.empresa_id=p_company AND p.rol=p_role
 AND (p_id IS NULL OR t.id=p_id) AND (p_after IS NULL OR t.id>p_after)
 ORDER BY t.id LIMIT p_limit) q;
 IF p_id IS NOT NULL AND jsonb_array_length(result)=0 THEN
  RAISE EXCEPTION 'Party not found' USING ERRCODE='P0002'; END IF;
 RETURN CASE WHEN p_id IS NULL THEN result ELSE result->0 END;
END $$;

CREATE OR REPLACE FUNCTION administracion.party_write_v2(
 p_company uuid,p_role text,p_action text,p_id uuid,p_code text,p_name text,
 p_version bigint,p_key text DEFAULT NULL,p_details jsonb DEFAULT '{}'::jsonb,p_profile_version bigint DEFAULT NULL,p_catalog_version bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,administracion,catalogo,plataforma,organizacion,auditoria,pg_temp AS $$
DECLARE actor uuid:=plataforma.current_app_user_id(); tenant uuid:=plataforma.current_app_tenant_id();
 operation text; cache_key text; fingerprint text; cached plataforma.idempotency_keys%ROWTYPE;
 third catalogo.terceros%ROWTYPE; result jsonb; correlation uuid;
 supplier catalogo.proveedores_catalogo%ROWTYPE; supplier_existed boolean; code_changed boolean:=false; shared_details jsonb;
 profile administracion.perfiles_tercero%ROWTYPE; terms jsonb; condition uuid; edition integer; condition_code text;
BEGIN
 IF p_company IS NULL OR p_role IS NULL OR p_role NOT IN ('cliente','proveedor')
 OR p_action IS NULL OR p_action NOT IN ('create','update') THEN
  RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023'; END IF;
 IF plataforma.has_current_tenant_capability('erp.finance','administration.parties.write',p_company) IS NOT TRUE
 OR plataforma.has_current_tenant_capability('erp.finance','administration.parties.read',p_company) IS NOT TRUE THEN
  RAISE EXCEPTION 'Party access denied' USING ERRCODE='42501'; END IF;
 IF administracion.valid_party_extension(p_details) IS NOT TRUE THEN RAISE EXCEPTION 'Invalid party details' USING ERRCODE='22023'; END IF;
 IF p_role='cliente' AND NULLIF(p_details->'condiciones'->>'moneda','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM catalogo.monedas WHERE codigo=p_details->'condiciones'->>'moneda') THEN RAISE EXCEPTION 'Unknown preferred currency' USING ERRCODE='22023'; END IF;
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
   IF NOT (p_details ? 'datos_generales' OR p_details ? 'contactos') THEN
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
 IF p_role='proveedor' OR EXISTS(SELECT 1 FROM catalogo.proveedores_catalogo WHERE tenant_id=tenant AND tercero_id=third.id) THEN
  SELECT * INTO supplier FROM catalogo.proveedores_catalogo WHERE tenant_id=tenant AND tercero_id=third.id FOR UPDATE;
  supplier_existed:=FOUND;
  IF p_action='update' AND (p_details ? 'datos_generales' OR p_details ? 'contactos')
   AND (p_catalog_version IS NULL OR p_catalog_version<>(CASE WHEN supplier_existed THEN supplier.version ELSE 0 END)) THEN
   RAISE EXCEPTION 'Stale catalog supplier version' USING ERRCODE='40001'; END IF;
  IF NOT supplier_existed THEN
   INSERT INTO catalogo.proveedores_catalogo(tenant_id,tercero_id,codigo,contacto,creado_por)
    VALUES(tenant,third.id,third.codigo,COALESCE(third.datos_administrativos,'{}'),actor) RETURNING * INTO supplier;
  END IF;
  IF p_details ? 'datos_generales' OR p_details ? 'contactos' THEN
   shared_details:=catalogo.normalizar_contacto_administrativo(jsonb_strip_nulls(COALESCE(third.datos_administrativos,supplier.contacto,'{}'::jsonb)||COALESCE(p_details->'datos_generales','{}'::jsonb))||CASE WHEN p_details ? 'contactos' THEN jsonb_build_object('personas',p_details->'contactos') ELSE '{}'::jsonb END);
   UPDATE catalogo.proveedores_catalogo SET codigo=CASE WHEN code_changed THEN third.codigo ELSE codigo END,contacto=shared_details,
    version=version+1,actualizado_en=transaction_timestamp() WHERE tenant_id=tenant AND tercero_id=third.id;
  END IF;
 END IF;
 IF p_details ? 'datos_generales' OR p_details ? 'contactos' THEN
  shared_details:=catalogo.normalizar_contacto_administrativo(jsonb_strip_nulls(COALESCE(third.datos_administrativos,shared_details,'{}'::jsonb)||COALESCE(p_details->'datos_generales','{}'::jsonb))||CASE WHEN p_details ? 'contactos' THEN jsonb_build_object('personas',p_details->'contactos') ELSE '{}'::jsonb END);
  UPDATE catalogo.terceros SET datos_administrativos=shared_details WHERE tenant_id=tenant AND id=third.id RETURNING * INTO third;
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

CREATE OR REPLACE FUNCTION catalogo.proveedores_leer(p_id uuid DEFAULT NULL,p_estado text DEFAULT NULL,p_limit integer DEFAULT 100) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,catalogo,plataforma,pg_temp AS $$ DECLARE result jsonb;BEGIN IF p_limit NOT BETWEEN 1 AND 101 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023';END IF;IF plataforma.has_current_tenant_capability('erp.catalog','catalog.suppliers.read') IS NOT TRUE THEN RAISE EXCEPTION 'Supplier access denied' USING ERRCODE='42501';END IF;SELECT COALESCE(jsonb_agg(item ORDER BY nombre,id),'[]') INTO result FROM(SELECT t.nombre,t.id,jsonb_build_object('id',t.id,'code',s.codigo,'name',t.nombre,'status',s.estado,'contact',COALESCE(t.datos_administrativos,s.contacto),'terms',s.condiciones,'version',s.version,'updated_at',s.actualizado_en) item FROM catalogo.proveedores_catalogo s JOIN catalogo.terceros t ON(t.tenant_id,t.id)=(s.tenant_id,s.tercero_id) WHERE s.tenant_id=plataforma.current_app_tenant_id() AND(p_id IS NULL OR s.tercero_id=p_id)AND(p_estado IS NULL OR s.estado=p_estado)ORDER BY t.nombre,t.id LIMIT p_limit)q;IF p_id IS NOT NULL AND jsonb_array_length(result)=0 THEN RAISE EXCEPTION 'Supplier not found' USING ERRCODE='P0002';END IF;RETURN CASE WHEN p_id IS NULL THEN result ELSE result->0 END;END $$;

CREATE OR REPLACE FUNCTION catalogo.proveedor_crear(p_codigo text,p_nombre text,p_contacto jsonb,p_condiciones jsonb,p_key varchar) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,catalogo,plataforma,auditoria,pg_temp AS $$ DECLARE actor uuid:=plataforma.current_app_user_id();tenant uuid:=plataforma.current_app_tenant_id();op text:='catalog.suppliers.create';corr uuid;fp text;cached plataforma.idempotency_keys%ROWTYPE;party uuid:=gen_random_uuid();response jsonb;BEGIN IF length(btrim(p_codigo)) NOT BETWEEN 1 AND 80 OR length(btrim(p_nombre)) NOT BETWEEN 1 AND 200 OR jsonb_typeof(COALESCE(p_contacto,'{}'))<>'object' OR jsonb_typeof(COALESCE(p_condiciones,'{}'))<>'object' OR length(p_key) NOT BETWEEN 1 AND 128 THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023';END IF;IF plataforma.has_current_tenant_capability('erp.catalog','catalog.suppliers.write') IS NOT TRUE OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM op THEN RAISE EXCEPTION 'Supplier creation denied' USING ERRCODE='42501';END IF;corr:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;fp:=encode(public.digest(jsonb_build_array(p_codigo,p_nombre,p_contacto,p_condiciones)::text,'sha256'),'hex');PERFORM pg_advisory_xact_lock(hashtextextended(p_key,0));SELECT * INTO cached FROM plataforma.idempotency_keys WHERE idempotency_key=p_key;IF FOUND THEN IF cached.actor_user_id<>actor OR cached.request_tenant_id<>tenant OR cached.operation<>op OR cached.request_fingerprint<>fp THEN RAISE EXCEPTION 'Idempotency conflict' USING ERRCODE='23505';END IF;RETURN cached.response_payload;END IF;INSERT INTO catalogo.terceros(id,tenant_id,codigo,nombre,datos_administrativos)VALUES(party,tenant,p_codigo,btrim(p_nombre),catalogo.normalizar_contacto_administrativo(CASE WHEN COALESCE(p_contacto,'{}') ? 'phone' THEN p_contacto||jsonb_build_object('telefono',p_contacto->'phone') ELSE COALESCE(p_contacto,'{}') END));INSERT INTO catalogo.roles_tercero VALUES(tenant,party,'proveedor');INSERT INTO catalogo.proveedores_catalogo(tenant_id,tercero_id,codigo,contacto,condiciones,creado_por)VALUES(tenant,party,p_codigo,COALESCE(p_contacto,'{}'),COALESCE(p_condiciones,'{}'),actor);response:=catalogo.proveedores_leer(party);INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,request_fingerprint,request_tenant_id,response_payload)VALUES(p_key,actor,op,party,fp,tenant,response);INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)VALUES(tenant,actor,'2.1.5-suppliers','tercero',party,op,corr,'{}');RETURN response;END $$;

CREATE OR REPLACE FUNCTION catalogo.proveedor_actualizar(p_id uuid,p_version bigint,p_cambios jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,catalogo,plataforma,auditoria,pg_temp AS $$ DECLARE tenant uuid:=plataforma.current_app_tenant_id();actor uuid:=plataforma.current_app_user_id();current catalogo.proveedores_catalogo%ROWTYPE;corr uuid;key text;BEGIN IF p_version IS NULL OR jsonb_typeof(p_cambios)<>'object' OR p_cambios='{}' THEN RAISE EXCEPTION 'Invalid input' USING ERRCODE='22023';END IF;FOR key IN SELECT jsonb_object_keys(p_cambios) LOOP IF key NOT IN('name','status','contact','terms')THEN RAISE EXCEPTION 'Unsupported supplier field' USING ERRCODE='22023';END IF;END LOOP;IF plataforma.has_current_tenant_capability('erp.catalog','catalog.suppliers.write') IS NOT TRUE OR NULLIF(current_setting('app.current_operation',true),'') IS DISTINCT FROM 'catalog.suppliers.update' THEN RAISE EXCEPTION 'Supplier update denied' USING ERRCODE='42501';END IF;SELECT * INTO current FROM catalogo.proveedores_catalogo WHERE tenant_id=tenant AND tercero_id=p_id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'Supplier not found' USING ERRCODE='P0002';END IF;IF current.version<>p_version THEN RAISE EXCEPTION 'Stale supplier version' USING ERRCODE='40001';END IF;IF p_cambios?'name' OR p_cambios?'contact' THEN UPDATE catalogo.terceros SET nombre=CASE WHEN p_cambios?'name' THEN btrim(p_cambios->>'name') ELSE nombre END,datos_administrativos=CASE WHEN p_cambios?'contact' THEN COALESCE(datos_administrativos,current.contacto,'{}'::jsonb)||catalogo.normalizar_contacto_administrativo(CASE WHEN (p_cambios->'contact') ? 'phone' THEN (p_cambios->'contact')||jsonb_build_object('telefono',p_cambios->'contact'->'phone') ELSE p_cambios->'contact' END) ELSE datos_administrativos END,version=version+1 WHERE tenant_id=tenant AND id=p_id;END IF;UPDATE catalogo.proveedores_catalogo SET estado=CASE WHEN p_cambios?'status' THEN p_cambios->>'status' ELSE estado END,contacto=CASE WHEN p_cambios?'contact' THEN COALESCE((SELECT t.datos_administrativos FROM catalogo.terceros t WHERE t.tenant_id=tenant AND t.id=p_id),contacto,'{}'::jsonb)||catalogo.normalizar_contacto_administrativo(CASE WHEN (p_cambios->'contact') ? 'phone' THEN (p_cambios->'contact')||jsonb_build_object('telefono',p_cambios->'contact'->'phone') ELSE p_cambios->'contact' END) ELSE contacto END,condiciones=CASE WHEN p_cambios?'terms' THEN p_cambios->'terms' ELSE condiciones END,version=version+1,actualizado_en=transaction_timestamp() WHERE tenant_id=tenant AND tercero_id=p_id;corr:=NULLIF(current_setting('app.correlation_id',true),'')::uuid;INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)VALUES(tenant,actor,'2.1.5-suppliers','tercero',p_id,'catalog.suppliers.update',corr,'{}');RETURN catalogo.proveedores_leer(p_id);END $$;
