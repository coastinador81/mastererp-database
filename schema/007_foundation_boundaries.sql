-- Forward overlay on the reconciled, immutable shared-identity 006 baseline.
-- No existing rows are deleted or reassigned. Tests use rollback-only fixtures.
CREATE OR REPLACE FUNCTION plataforma.user_has_tenant_access(p_tenant_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, plataforma, pg_temp AS $$
 SELECT p_tenant_id=plataforma.current_app_tenant_id() AND EXISTS (
 SELECT 1 FROM plataforma.user_tenants ut JOIN plataforma.users u ON u.id=ut.user_id
 JOIN plataforma.tenants t ON t.id=ut.tenant_id
 WHERE ut.tenant_id=p_tenant_id AND ut.user_id=plataforma.current_app_user_id()
 AND ut.status='active' AND u.status='active' AND t.status IN ('draft','active')
 AND t.deleted_at IS NULL);
$$;
REVOKE ALL ON FUNCTION plataforma.user_has_tenant_access(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION plataforma.user_has_tenant_access(uuid) TO mastererp_app;

CREATE UNIQUE INDEX IF NOT EXISTS companies_tenant_id_id_uidx
 ON organizacion.companies(tenant_id,id);
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conname='branches_tenant_company_fk'
               AND conrelid='organizacion.branches'::regclass) THEN
  ALTER TABLE organizacion.branches ADD CONSTRAINT branches_tenant_company_fk
   FOREIGN KEY(tenant_id,company_id) REFERENCES organizacion.companies(tenant_id,id) NOT VALID;
 END IF;
 -- Do not destroy, reassign or silently repair legacy inconsistent rows.
 IF NOT EXISTS(SELECT 1 FROM organizacion.branches b WHERE NOT EXISTS
   (SELECT 1 FROM organizacion.companies c WHERE c.id=b.company_id AND c.tenant_id=b.tenant_id)) THEN
  ALTER TABLE organizacion.branches VALIDATE CONSTRAINT branches_tenant_company_fk;
 END IF;
END $$;

CREATE OR REPLACE FUNCTION plataforma.current_onboarding_context_active()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, plataforma, pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM plataforma.user_tenants ut
 JOIN plataforma.users u ON u.id=ut.user_id JOIN plataforma.tenants t ON t.id=ut.tenant_id
 WHERE ut.user_id=plataforma.current_app_user_id()
 AND ut.tenant_id=plataforma.current_app_tenant_id()
 AND ut.status='active' AND u.status='active' AND t.status IN ('draft','active')
 AND t.deleted_at IS NULL);
$$;
REVOKE ALL ON FUNCTION plataforma.current_onboarding_context_active() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION plataforma.current_onboarding_context_active() TO mastererp_app;

-- Restrictive policies compose with the existing owner policies: no new grants.
DROP POLICY IF EXISTS foundation_company_context ON organizacion.companies;
CREATE POLICY foundation_company_context ON organizacion.companies AS RESTRICTIVE
 FOR ALL TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.current_onboarding_context_active())
 WITH CHECK
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.current_onboarding_context_active());
DROP POLICY IF EXISTS foundation_branch_context ON organizacion.branches;
CREATE POLICY foundation_branch_context ON organizacion.branches AS RESTRICTIVE
 FOR ALL TO mastererp_app USING
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.current_onboarding_context_active()
 AND EXISTS(SELECT 1 FROM organizacion.companies c WHERE c.id=company_id AND c.tenant_id=branches.tenant_id))
 WITH CHECK
 (tenant_id=plataforma.current_app_tenant_id() AND plataforma.current_onboarding_context_active()
 AND EXISTS(SELECT 1 FROM organizacion.companies c WHERE c.id=company_id AND c.tenant_id=branches.tenant_id));

CREATE OR REPLACE FUNCTION plataforma.has_current_tenant_capability(
 p_module_code text,p_permission_code text,p_company_id uuid DEFAULT NULL,p_branch_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, plataforma, organizacion, pg_temp AS $$
 SELECT plataforma.has_current_tenant_permission(p_permission_code)
 AND EXISTS(SELECT 1 FROM plataforma.tenant_modules tm JOIN plataforma.modules m ON m.id=tm.module_id
 WHERE tm.tenant_id=plataforma.current_app_tenant_id() AND m.code=p_module_code
 AND tm.status='active' AND m.status='active' AND (tm.expires_at IS NULL OR tm.expires_at>now()))
 AND (p_company_id IS NULL OR EXISTS(SELECT 1 FROM organizacion.companies c
 WHERE c.id=p_company_id AND c.tenant_id=plataforma.current_app_tenant_id() AND c.status='active'))
 AND (p_branch_id IS NULL OR (p_company_id IS NOT NULL AND EXISTS(SELECT 1 FROM organizacion.branches b
 WHERE b.id=p_branch_id AND b.company_id=p_company_id
 AND b.tenant_id=plataforma.current_app_tenant_id() AND b.status='active')));
$$;
REVOKE ALL ON FUNCTION plataforma.has_current_tenant_capability(text,text,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION plataforma.has_current_tenant_capability(text,text,uuid,uuid) TO mastererp_app;
-- Company checks here establish tenant containment, not a new per-user company ACL.

ALTER TABLE plataforma.idempotency_keys ADD COLUMN IF NOT EXISTS request_fingerprint text;
ALTER TABLE plataforma.idempotency_keys ADD COLUMN IF NOT EXISTS request_tenant_id uuid REFERENCES plataforma.tenants(id);
DROP POLICY IF EXISTS idempotency_actor_select ON plataforma.idempotency_keys;
CREATE POLICY idempotency_actor_select ON plataforma.idempotency_keys FOR SELECT TO mastererp_app
 USING(actor_user_id=plataforma.current_app_user_id()
 AND operation=NULLIF(current_setting('app.current_operation',true),'')
 AND request_tenant_id IS NOT DISTINCT FROM plataforma.current_app_tenant_id());
CREATE OR REPLACE FUNCTION plataforma.create_tenant_with_owner(
 p_code varchar,p_slug varchar,p_name varchar,p_tenant_type varchar,
 p_owner_user_id uuid,p_idempotency_key varchar DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, plataforma, pg_temp AS $$
DECLARE
 v_tenant_id uuid; v_role uuid; v_cache plataforma.idempotency_keys%ROWTYPE;
 v_fingerprint text;
BEGIN
 IF plataforma.current_app_user_id() IS NULL
 OR p_owner_user_id IS DISTINCT FROM plataforma.current_app_user_id()
 OR plataforma.current_app_tenant_id() IS NOT NULL
 OR NOT EXISTS(SELECT 1 FROM plataforma.users WHERE id=p_owner_user_id AND status='active')
 THEN RAISE EXCEPTION 'Unauthorized tenant creation' USING ERRCODE='42501'; END IF;
 v_fingerprint:=encode(sha256(convert_to(jsonb_build_object(
  'actor',p_owner_user_id,'tenant_context',NULL,'operation','tenant.create',
  'code',p_code,'slug',p_slug,'name',p_name,'type',p_tenant_type)::text,'UTF8')),'hex');
 IF p_idempotency_key IS NOT NULL THEN
  IF length(p_idempotency_key) NOT BETWEEN 1 AND 128 THEN
   RAISE EXCEPTION 'Invalid idempotency key' USING ERRCODE='22023'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
  SELECT * INTO v_cache FROM plataforma.idempotency_keys WHERE idempotency_key=p_idempotency_key;
  IF FOUND THEN
   IF v_cache.actor_user_id<>p_owner_user_id OR v_cache.operation<>'tenant.create' THEN
    RAISE EXCEPTION 'Idempotency key unavailable' USING ERRCODE='42501'; END IF;
   IF v_cache.request_fingerprint IS DISTINCT FROM v_fingerprint OR v_cache.expires_at<=now() THEN
    RAISE EXCEPTION 'Idempotency request conflict' USING ERRCODE='23505'; END IF;
   RETURN (v_cache.response_body->>'tenant_id')::uuid;
  END IF;
 END IF;
 SELECT id INTO v_role FROM plataforma.roles WHERE code='tenant.owner';
 IF v_role IS NULL THEN RAISE EXCEPTION 'Missing owner role'; END IF;
 INSERT INTO plataforma.tenants(code,slug,name,tenant_type,status)
 VALUES(p_code,p_slug,p_name,p_tenant_type,'draft') RETURNING id INTO v_tenant_id;
 INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status,joined_at)
 VALUES(v_tenant_id,p_owner_user_id,v_role,'active',now());
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(v_tenant_id,p_owner_user_id,'1.1-tenant-onboarding','tenant',v_tenant_id,'tenant.created',
 COALESCE(NULLIF(current_setting('app.correlation_id',true),'')::uuid,gen_random_uuid()),jsonb_build_object('result','succeeded'));
 IF p_idempotency_key IS NOT NULL THEN
  INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,response_body,request_fingerprint)
  VALUES(p_idempotency_key,p_owner_user_id,'tenant.create',v_tenant_id,
   jsonb_build_object('tenant_id',v_tenant_id),v_fingerprint);
 END IF;
 RETURN v_tenant_id;
END $$;
REVOKE ALL ON FUNCTION plataforma.create_tenant_with_owner(varchar,varchar,varchar,varchar,uuid,varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION plataforma.create_tenant_with_owner(varchar,varchar,varchar,varchar,uuid,varchar) TO mastererp_app;
-- The existing global client-key uniqueness contract is retained. Changing its
-- scope or reusing expired/legacy keys requires a separately agreed transition.

CREATE OR REPLACE FUNCTION organizacion.register_company_once(
 p_key varchar,p_legal_name varchar,p_country_code varchar,p_currency varchar,
 p_timezone varchar,p_tax_identifier varchar DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, plataforma, organizacion, pg_temp AS $$
DECLARE
 v_actor uuid:=plataforma.current_app_user_id();
 v_tenant uuid:=plataforma.current_app_tenant_id();
 v_fingerprint text; v_cache plataforma.idempotency_keys%ROWTYPE; v_id uuid;
BEGIN
 -- Preserve existing onboarding owner-only company-management contract.
 IF NOT COALESCE(plataforma.current_onboarding_context_active(),false)
 OR NOT COALESCE(plataforma.user_owns_current_tenant(v_tenant),false)
 THEN RAISE EXCEPTION 'Company registration denied' USING ERRCODE='42501'; END IF;
 IF p_key IS NULL OR length(p_key) NOT BETWEEN 1 AND 128 OR p_legal_name IS NULL
 OR length(btrim(p_legal_name))=0 OR p_country_code IS NULL OR p_currency IS NULL
 OR length(p_country_code)<>2 OR length(p_currency)<>3
 OR p_timezone IS NULL OR length(btrim(p_timezone))=0 THEN
 RAISE EXCEPTION 'Invalid company request' USING ERRCODE='22023'; END IF;
 v_fingerprint:=encode(sha256(convert_to(jsonb_build_object(
 'actor',v_actor,'tenant',v_tenant,'operation','company.create','name',p_legal_name,
 'country',p_country_code,'currency',p_currency,'timezone',p_timezone,'tax',p_tax_identifier)::text,'UTF8')),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_key,0));
 SELECT * INTO v_cache FROM plataforma.idempotency_keys WHERE idempotency_key=p_key;
 IF FOUND THEN
  IF v_cache.actor_user_id<>v_actor OR v_cache.operation<>'company.create' THEN
   RAISE EXCEPTION 'Idempotency key unavailable' USING ERRCODE='42501'; END IF;
  IF v_cache.request_fingerprint IS DISTINCT FROM v_fingerprint OR v_cache.expires_at<=now() THEN
   RAISE EXCEPTION 'Idempotency request conflict' USING ERRCODE='23505'; END IF;
  RETURN v_cache.resource_id;
 END IF;
 INSERT INTO organizacion.companies(tenant_id,legal_name,country_code,base_currency_code,timezone,tax_identifier)
 VALUES(v_tenant,p_legal_name,p_country_code,p_currency,p_timezone,p_tax_identifier) RETURNING id INTO v_id;
 INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
 VALUES(v_tenant,v_actor,'1.1-tenant-onboarding','company',v_id,'company.created',
 COALESCE(NULLIF(current_setting('app.correlation_id',true),'')::uuid,gen_random_uuid()),jsonb_build_object('result','succeeded'));
 INSERT INTO plataforma.idempotency_keys(idempotency_key,actor_user_id,operation,resource_id,response_body,request_fingerprint,request_tenant_id)
 VALUES(p_key,v_actor,'company.create',v_id,jsonb_build_object('company_id',v_id),v_fingerprint,v_tenant);
 RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION organizacion.register_company_once(varchar,varchar,varchar,varchar,varchar,varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION organizacion.register_company_once(varchar,varchar,varchar,varchar,varchar,varchar) TO mastererp_app;
-- This function is not an HTTP operation until backend authorization and publication
-- are integrated. No company-specific membership ACL is invented by this overlay.
