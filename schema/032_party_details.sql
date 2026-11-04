-- Additive Finance supplier details over the canonical Catalog supplier from migration 024. Existing migrations, RLS, v1 signatures and grants are preserved.
ALTER TABLE administracion.perfiles_tercero ADD COLUMN IF NOT EXISTS datos_comerciales jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE OR REPLACE FUNCTION administracion.valid_party_extension(p jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE k text; v jsonb; section jsonb; item jsonb; principal_count integer:=0; value text;
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR octet_length(p::text)>16000 THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_object_keys(p) x WHERE x NOT IN ('datos_generales','contactos','condiciones')) THEN RETURN false; END IF;
 IF p ? 'datos_generales' THEN
  section:=p->'datos_generales'; IF jsonb_typeof(section) IS DISTINCT FROM 'object' THEN RETURN false; END IF;
  FOR k,v IN SELECT * FROM jsonb_each(section) LOOP
   IF k NOT IN ('nombre_comercial','tipo_persona','pais_fiscal','tipo_identificacion','numero_identificacion','direccion','direccion_complementaria','ciudad','municipio','region','codigo_postal','pais','email','telefono','telefono_alterno','sitio_web','observaciones') THEN RETURN false; END IF;
   IF v='null'::jsonb THEN CONTINUE; END IF;
   IF jsonb_typeof(v)<>'string' THEN RETURN false; END IF; value:=v#>>'{}';
   IF length(value)>(CASE k WHEN 'observaciones' THEN 2000 WHEN 'sitio_web' THEN 300 WHEN 'email' THEN 254 WHEN 'direccion' THEN 250 WHEN 'direccion_complementaria' THEN 250 WHEN 'nombre_comercial' THEN 200 WHEN 'ciudad' THEN 100 WHEN 'municipio' THEN 100 WHEN 'region' THEN 100 WHEN 'numero_identificacion' THEN 50 WHEN 'telefono' THEN 40 WHEN 'telefono_alterno' THEN 40 WHEN 'tipo_identificacion' THEN 30 WHEN 'codigo_postal' THEN 20 ELSE 30 END) THEN RETURN false; END IF;
   IF k<>'observaciones' AND value ~ '[[:cntrl:]]' THEN RETURN false; END IF;
   IF value<>'' AND ((k IN ('pais','pais_fiscal') AND value !~ '^[A-Z]{2}$') OR (k='tipo_persona' AND value NOT IN ('natural','juridica')) OR (k='email' AND value !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') OR (k='sitio_web' AND value !~ '^https?://[^[:space:]]+$')) THEN RETURN false; END IF;
  END LOOP;
 END IF;
 IF p ? 'contactos' THEN
  section:=p->'contactos'; IF jsonb_typeof(section) IS DISTINCT FROM 'array' THEN RETURN false; END IF;
  IF jsonb_array_length(section)>10 THEN RETURN false; END IF;
  FOR item IN SELECT * FROM jsonb_array_elements(section) LOOP
   IF jsonb_typeof(item) IS DISTINCT FROM 'object' THEN RETURN false; END IF;
   FOR k,v IN SELECT * FROM jsonb_each(item) LOOP
    IF k NOT IN ('nombre','cargo','email','telefono','principal') THEN RETURN false; END IF;
    IF k='principal' THEN
     IF jsonb_typeof(v) IS DISTINCT FROM 'boolean' THEN RETURN false; END IF;
     IF v='true'::jsonb THEN principal_count:=principal_count+1; END IF;
    ELSE
     IF jsonb_typeof(v) IS DISTINCT FROM 'string' THEN RETURN false; END IF; value:=v#>>'{}';
     IF length(value)>(CASE k WHEN 'nombre' THEN 150 WHEN 'cargo' THEN 100 WHEN 'email' THEN 254 ELSE 40 END) OR value ~ '[[:cntrl:]]' THEN RETURN false; END IF;
     IF k='email' AND value<>'' AND value !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' THEN RETURN false; END IF;
    END IF;
   END LOOP;
  END LOOP;
  IF principal_count>1 THEN RETURN false; END IF;
 END IF;
 IF p ? 'condiciones' THEN
  section:=p->'condiciones'; IF jsonb_typeof(section) IS DISTINCT FROM 'object' THEN RETURN false; END IF;
  FOR k,v IN SELECT * FROM jsonb_each(section) LOOP
   IF k NOT IN ('moneda','tipo_suministro','condicion_pago','medio_pago','plazo_pago_dias','descuento_pronto_pago','plazo_pronto_pago_dias') OR jsonb_typeof(v) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
   value:=v#>>'{}'; IF length(value)>30 OR value ~ '[[:cntrl:]]' THEN RETURN false; END IF;
   IF value<>'' THEN
    IF k='moneda' AND value !~ '^[A-Z]{3}$' THEN RETURN false; END IF;
    IF k='tipo_suministro' AND value NOT IN ('productos','servicios','ambos') THEN RETURN false; END IF;
    IF k='condicion_pago' AND value NOT IN ('contado','credito','por_acordar') THEN RETURN false; END IF;
    IF k='medio_pago' AND value NOT IN ('transferencia','efectivo','tarjeta','otro') THEN RETURN false; END IF;
    IF k IN ('plazo_pago_dias','plazo_pronto_pago_dias') AND (value !~ '^[0-9]{1,10}$' OR value::numeric>2147483647) THEN RETURN false; END IF;
    IF k='descuento_pronto_pago' AND (value !~ '^[0-9]+([.][0-9]{1,6})?$' OR value::numeric>100) THEN RETURN false; END IF;
   END IF;
  END LOOP;
  IF (NULLIF(section->>'descuento_pronto_pago','') IS NULL) IS DISTINCT FROM (NULLIF(section->>'plazo_pronto_pago_dias','') IS NULL) THEN RETURN false; END IF;
 END IF;
 RETURN true;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN RETURN false;
END $$;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conname='perfil_extension_valid' AND conrelid='administracion.perfiles_tercero'::regclass) THEN
  ALTER TABLE administracion.perfiles_tercero ADD CONSTRAINT perfil_extension_valid CHECK(administracion.valid_party_extension(jsonb_build_object('condiciones',datos_comerciales)));
 END IF;
END $$;
REVOKE ALL ON FUNCTION administracion.valid_party_extension(jsonb) FROM PUBLIC;

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
  'datos_generales',COALESCE((SELECT jsonb_object_agg(k,v) FROM jsonb_each(COALESCE(s.contacto,'{}'::jsonb)) e(k,v) WHERE k IN ('nombre_comercial','tipo_persona','pais_fiscal','tipo_identificacion','numero_identificacion','direccion','direccion_complementaria','ciudad','municipio','region','codigo_postal','pais','email','telefono','telefono_alterno','sitio_web','observaciones')),'{}'::jsonb),
  'contactos',CASE WHEN jsonb_typeof(s.contacto->'personas')='array' THEN s.contacto->'personas' ELSE '[]'::jsonb END,'catalog_version',COALESCE(s.version,0),'catalog_status',s.estado,
  'condiciones',COALESCE(p.datos_comerciales,'{}'::jsonb)||jsonb_build_object(
    'plazo_pago_dias',COALESCE((SELECT c.dias_plazo::text FROM administracion.condiciones_comerciales c WHERE c.id=p.condicion_id AND c.tenant_id=p.tenant_id AND c.empresa_id=p.empresa_id),''),
    'descuento_pronto_pago',COALESCE((SELECT d.porcentaje::text FROM administracion.descuentos_pronto_pago d WHERE d.condicion_id=p.condicion_id AND d.tenant_id=p.tenant_id AND d.empresa_id=p.empresa_id LIMIT 1),''),
    'plazo_pronto_pago_dias',COALESCE((SELECT d.hasta_dias::text FROM administracion.descuentos_pronto_pago d WHERE d.condicion_id=p.condicion_id AND d.tenant_id=p.tenant_id AND d.empresa_id=p.empresa_id LIMIT 1),'')),
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
 supplier catalogo.proveedores_catalogo%ROWTYPE; supplier_existed boolean;
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
   UPDATE catalogo.proveedores_catalogo SET contacto=jsonb_strip_nulls(contacto||COALESCE(p_details->'datos_generales','{}'::jsonb))||
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
REVOKE ALL ON FUNCTION administracion.parties_read_v2(uuid,text,uuid,integer,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION administracion.party_write_v2(uuid,text,text,uuid,text,text,bigint,text,jsonb,bigint,bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION administracion.parties_read_v2(uuid,text,uuid,integer,uuid),
 administracion.party_write_v2(uuid,text,text,uuid,text,text,bigint,text,jsonb,bigint,bigint) TO mastererp_app;
