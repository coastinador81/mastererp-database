-- Shared identity + tenant authorization. No users, identities or memberships seeded.
CREATE TABLE IF NOT EXISTS plataforma.external_identities (
 issuer text NOT NULL CHECK (issuer LIKE 'https://%'),
 subject text NOT NULL CHECK (length(subject) BETWEEN 1 AND 255),
 user_id uuid NOT NULL REFERENCES plataforma.users(id),
 status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (issuer, subject)
);
CREATE INDEX IF NOT EXISTS external_identities_user_idx ON plataforma.external_identities(user_id);
ALTER TABLE plataforma.external_identities ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON plataforma.external_identities FROM PUBLIC, mastererp_app;

CREATE TABLE IF NOT EXISTS plataforma.permissions (
 code text PRIMARY KEY,
 description text NOT NULL
);
CREATE TABLE IF NOT EXISTS plataforma.role_permissions (
 role_id uuid NOT NULL REFERENCES plataforma.roles(id),
 permission_code text NOT NULL REFERENCES plataforma.permissions(code),
 PRIMARY KEY (role_id, permission_code)
);
REVOKE ALL ON plataforma.permissions, plataforma.role_permissions FROM PUBLIC, mastererp_app;
GRANT SELECT ON plataforma.permissions, plataforma.role_permissions TO mastererp_app;
-- tenant.owner is the only tenant administrative role present in the model.
-- platform.admin is NOT a tenant administrator and receives no implicit grant.
-- Seed the initial role grant only when creating the permission. Reapplication
-- must not resurrect a role grant that an authorized administrator later revoked.
WITH new_permission AS (
 INSERT INTO plataforma.permissions(code,description)
 VALUES ('uonify.connections.manage','Administer Uonify connections within an active tenant')
 ON CONFLICT (code) DO NOTHING RETURNING code
)
INSERT INTO plataforma.role_permissions(role_id,permission_code)
 SELECT r.id,p.code FROM plataforma.roles r CROSS JOIN new_permission p WHERE r.code='tenant.owner'
 ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION plataforma.resolve_external_identity(p_issuer text,p_subject text)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, plataforma, pg_temp AS $$
 SELECT e.user_id FROM plataforma.external_identities e
 JOIN plataforma.users u ON u.id=e.user_id
 WHERE e.issuer=p_issuer AND e.subject=p_subject AND e.status='active' AND u.status='active';
$$;

CREATE OR REPLACE FUNCTION plataforma.has_current_tenant_permission(p_code text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, plataforma, pg_temp AS $$
 SELECT EXISTS (
 SELECT 1 FROM plataforma.user_tenants ut
 JOIN plataforma.users u ON u.id=ut.user_id
 JOIN plataforma.tenants t ON t.id=ut.tenant_id
 WHERE ut.user_id=plataforma.current_app_user_id()
 AND ut.tenant_id=plataforma.current_app_tenant_id()
 AND ut.status='active' AND u.status='active' AND t.status='active' AND t.deleted_at IS NULL
 AND EXISTS(SELECT 1 FROM plataforma.permissions p WHERE p.code=p_code)
 AND CASE WHEN ut.permissions_override ? p_code THEN
   CASE WHEN jsonb_typeof(ut.permissions_override->p_code)='boolean'
     THEN (ut.permissions_override->>p_code)::boolean ELSE false END
 ELSE EXISTS(SELECT 1 FROM plataforma.role_permissions rp
             WHERE rp.role_id=ut.role_id AND rp.permission_code=p_code) END);
$$;

CREATE OR REPLACE FUNCTION plataforma.list_current_user_spaces()
RETURNS TABLE(tenant_id uuid,tenant_name varchar) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, plataforma, pg_temp AS $$
 SELECT t.id,t.name FROM plataforma.user_tenants ut
 JOIN plataforma.users u ON u.id=ut.user_id JOIN plataforma.tenants t ON t.id=ut.tenant_id
 WHERE ut.user_id=plataforma.current_app_user_id() AND u.status='active'
 AND ut.status='active' AND t.status='active' AND t.deleted_at IS NULL
 ORDER BY t.name,t.id;
$$;

REVOKE ALL ON FUNCTION plataforma.resolve_external_identity(text,text),
 plataforma.has_current_tenant_permission(text),plataforma.list_current_user_spaces() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION plataforma.resolve_external_identity(text,text),
 plataforma.has_current_tenant_permission(text),plataforma.list_current_user_spaces() TO mastererp_app;
-- These SECURITY DEFINER functions only return narrowly scoped reads; no writes,
-- dynamic SQL, email lookup, role changes or automatic identity linking.
-- JWT issuer/sub must be authenticated by the trusted backend before lookup.
