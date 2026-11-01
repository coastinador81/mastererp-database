-- Roles de aplicación (sin BYPASSRLS). El migrador usa el rol de administración de RDS.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mastererp_app') THEN
        CREATE ROLE mastererp_app NOINHERIT LOGIN;
    END IF;
END;
$$;

GRANT USAGE ON SCHEMA plataforma, organizacion, auditoria TO mastererp_app;
-- Explicit grants are applied after all tables and policies below.
ALTER DEFAULT PRIVILEGES IN SCHEMA plataforma REVOKE ALL ON TABLES FROM mastererp_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA organizacion REVOKE ALL ON TABLES FROM mastererp_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA auditoria REVOKE ALL ON TABLES FROM mastererp_app;

CREATE TABLE IF NOT EXISTS plataforma.idempotency_keys (
    idempotency_key varchar(128) PRIMARY KEY,
    actor_user_id uuid NOT NULL REFERENCES plataforma.users(id),
    operation varchar(80) NOT NULL,
    resource_id uuid,
    response_body jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL DEFAULT (now() + interval '24 hours')
);
CREATE INDEX IF NOT EXISTS idempotency_keys_actor_idx ON plataforma.idempotency_keys(actor_user_id, created_at DESC);

INSERT INTO plataforma.roles (code, name, description)
VALUES
    ('tenant.owner', 'Tenant Owner', 'Propietario inicial del tenant'),
    ('platform.admin', 'Platform Admin', 'Administración de plataforma')
ON CONFLICT (code) DO NOTHING;

CREATE OR REPLACE FUNCTION plataforma.current_app_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid;
$$;

CREATE OR REPLACE FUNCTION plataforma.current_app_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
$$;

CREATE OR REPLACE FUNCTION plataforma.user_has_tenant_access(p_tenant_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, plataforma, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM plataforma.user_tenants ut
        WHERE ut.tenant_id = p_tenant_id
          AND ut.user_id = plataforma.current_app_user_id()
          AND ut.status = 'active'
    );
$$;

CREATE OR REPLACE FUNCTION plataforma.create_tenant_with_owner(
    p_code varchar,
    p_slug varchar,
    p_name varchar,
    p_tenant_type varchar,
    p_owner_user_id uuid,
    p_idempotency_key varchar DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, plataforma, pg_temp
AS $$
DECLARE
    v_tenant_id uuid;
    v_owner_role_id uuid;
    v_cached jsonb;
BEGIN
    IF plataforma.current_app_user_id() IS NULL
       OR p_owner_user_id IS DISTINCT FROM plataforma.current_app_user_id()
       OR plataforma.current_app_tenant_id() IS NOT NULL
       OR NOT EXISTS (SELECT 1 FROM plataforma.users
                      WHERE id = p_owner_user_id AND status = 'active') THEN
        RAISE EXCEPTION 'Unauthorized tenant creation' USING ERRCODE = '42501';
    END IF;
    IF p_idempotency_key IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key, 0));
        IF EXISTS (SELECT 1 FROM plataforma.idempotency_keys
                   WHERE idempotency_key = p_idempotency_key
                     AND (actor_user_id <> p_owner_user_id OR operation <> 'tenant.create')) THEN
            RAISE EXCEPTION 'Idempotency key unavailable' USING ERRCODE = '42501';
        END IF;
    END IF;
    IF p_idempotency_key IS NOT NULL THEN
        SELECT response_body INTO v_cached
        FROM plataforma.idempotency_keys
        WHERE idempotency_key = p_idempotency_key
          AND actor_user_id = p_owner_user_id
          AND operation = 'tenant.create'
          AND expires_at > now();
        IF v_cached IS NOT NULL THEN
            RETURN (v_cached->>'tenant_id')::uuid;
        END IF;
    END IF;

    SELECT id INTO v_owner_role_id FROM plataforma.roles WHERE code = 'tenant.owner';
    IF v_owner_role_id IS NULL THEN
        RAISE EXCEPTION 'Missing tenant.owner role';
    END IF;

    INSERT INTO plataforma.tenants (code, slug, name, tenant_type, status)
    VALUES (p_code, p_slug, p_name, p_tenant_type, 'draft')
    RETURNING id INTO v_tenant_id;

    INSERT INTO plataforma.user_tenants (tenant_id, user_id, role_id, status, joined_at)
    VALUES (v_tenant_id, p_owner_user_id, v_owner_role_id, 'active', now());

    INSERT INTO auditoria.events (tenant_id, actor_user_id, module_code, entity_type, entity_id, action, metadata)
    VALUES (v_tenant_id, p_owner_user_id, '1.1-tenant-onboarding', 'tenant', v_tenant_id, 'tenant.created', '{}'::jsonb);

    IF p_idempotency_key IS NOT NULL THEN
        INSERT INTO plataforma.idempotency_keys (idempotency_key, actor_user_id, operation, resource_id, response_body)
        VALUES (
            p_idempotency_key,
            p_owner_user_id,
            'tenant.create',
            v_tenant_id,
            jsonb_build_object('tenant_id', v_tenant_id)
        );
    END IF;

    RETURN v_tenant_id;
END;
$$;

REVOKE ALL ON FUNCTION plataforma.create_tenant_with_owner(varchar, varchar, varchar, varchar, uuid, varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION plataforma.create_tenant_with_owner(varchar, varchar, varchar, varchar, uuid, varchar) TO mastererp_app;

ALTER TABLE plataforma.tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE plataforma.user_tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE plataforma.tenant_modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE plataforma.onboarding_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE plataforma.onboarding_step_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizacion.companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizacion.branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE auditoria.events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenants_member_select ON plataforma.tenants;
CREATE POLICY tenants_member_select ON plataforma.tenants
    FOR SELECT USING (plataforma.user_has_tenant_access(id));

DROP POLICY IF EXISTS user_tenants_member_select ON plataforma.user_tenants;
CREATE POLICY user_tenants_member_select ON plataforma.user_tenants
    FOR SELECT USING (user_id = plataforma.current_app_user_id() OR plataforma.user_has_tenant_access(tenant_id));

DROP POLICY IF EXISTS tenant_modules_member_all ON plataforma.tenant_modules;
CREATE POLICY tenant_modules_member_all ON plataforma.tenant_modules
    FOR ALL USING (plataforma.user_has_tenant_access(tenant_id))
    WITH CHECK (plataforma.user_has_tenant_access(tenant_id));

DROP POLICY IF EXISTS onboarding_sessions_member_all ON plataforma.onboarding_sessions;
CREATE POLICY onboarding_sessions_member_all ON plataforma.onboarding_sessions
    FOR ALL USING (
        initiated_by_user_id = plataforma.current_app_user_id()
        OR (tenant_id IS NOT NULL AND plataforma.user_has_tenant_access(tenant_id))
    )
    WITH CHECK (
        initiated_by_user_id = plataforma.current_app_user_id()
        OR (tenant_id IS NOT NULL AND plataforma.user_has_tenant_access(tenant_id))
    );

DROP POLICY IF EXISTS onboarding_step_responses_member_all ON plataforma.onboarding_step_responses;
CREATE POLICY onboarding_step_responses_member_all ON plataforma.onboarding_step_responses
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM plataforma.onboarding_sessions s
            WHERE s.id = session_id
              AND (
                  s.initiated_by_user_id = plataforma.current_app_user_id()
                  OR (s.tenant_id IS NOT NULL AND plataforma.user_has_tenant_access(s.tenant_id))
              )
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM plataforma.onboarding_sessions s
            WHERE s.id = session_id
              AND (
                  s.initiated_by_user_id = plataforma.current_app_user_id()
                  OR (s.tenant_id IS NOT NULL AND plataforma.user_has_tenant_access(s.tenant_id))
              )
        )
    );

DROP POLICY IF EXISTS companies_member_all ON organizacion.companies;
CREATE POLICY companies_member_all ON organizacion.companies
    FOR ALL USING (plataforma.user_has_tenant_access(tenant_id))
    WITH CHECK (plataforma.user_has_tenant_access(tenant_id));

DROP POLICY IF EXISTS branches_member_all ON organizacion.branches;
CREATE POLICY branches_member_all ON organizacion.branches
    FOR ALL USING (plataforma.user_has_tenant_access(tenant_id))
    WITH CHECK (plataforma.user_has_tenant_access(tenant_id));

DROP POLICY IF EXISTS events_member_select ON auditoria.events;
DROP POLICY IF EXISTS events_member_insert ON auditoria.events;
CREATE POLICY events_member_select ON auditoria.events
    FOR SELECT USING (tenant_id IS NULL OR plataforma.user_has_tenant_access(tenant_id));
CREATE POLICY events_member_insert ON auditoria.events
    FOR INSERT WITH CHECK (tenant_id IS NULL OR plataforma.user_has_tenant_access(tenant_id));
