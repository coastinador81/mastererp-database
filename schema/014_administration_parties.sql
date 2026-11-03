-- Controlled commands over the existing tenant master and company profiles.
ALTER TABLE plataforma.idempotency_keys ADD COLUMN IF NOT EXISTS response_payload jsonb;
WITH added AS (
 INSERT INTO plataforma.permissions(code,description) VALUES
 ('administration.parties.read','Read company customer/supplier profiles'),
 ('administration.parties.write','Create/update customer/supplier master and company profiles')
 ON CONFLICT DO NOTHING RETURNING code
)
INSERT INTO plataforma.role_permissions(role_id,permission_code)
SELECT r.id,a.code FROM plataforma.roles r CROSS JOIN added a WHERE r.code='tenant.owner'
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION administracion.parties_read(
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
  'roles',(SELECT jsonb_agg(x.rol ORDER BY x.rol) FROM administracion.perfiles_tercero x
   WHERE x.tenant_id=p.tenant_id AND x.empresa_id=p.empresa_id AND x.tercero_id=t.id)) item
 FROM catalogo.terceros t JOIN administracion.perfiles_tercero p
 ON (p.tenant_id,p.tercero_id)=(t.tenant_id,t.id)
 WHERE t.tenant_id=plataforma.current_app_tenant_id() AND p.empresa_id=p_company AND p.rol=p_role
 AND (p_id IS NULL OR t.id=p_id) AND (p_after IS NULL OR t.id>p_after)
 ORDER BY t.id LIMIT p_limit) q;
 IF p_id IS NOT NULL AND jsonb_array_length(result)=0 THEN
  RAISE EXCEPTION 'Party not found' USING ERRCODE='P0002'; END IF;
 RETURN CASE WHEN p_id IS NULL THEN result ELSE result->0 END;
END $$;

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
REVOKE ALL ON FUNCTION administracion.parties_read(uuid,text,uuid,integer,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION administracion.party_write(uuid,text,text,uuid,text,text,bigint,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION administracion.parties_read(uuid,text,uuid,integer,uuid),
 administracion.party_write(uuid,text,text,uuid,text,text,bigint,text) TO mastererp_app;
