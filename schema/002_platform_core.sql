CREATE OR REPLACE FUNCTION plataforma.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS plataforma.tenants (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code varchar(50) NOT NULL UNIQUE,
    slug varchar(100) NOT NULL UNIQUE,
    name varchar(200) NOT NULL,
    tenant_type varchar(30) NOT NULL DEFAULT 'individual'
        CHECK (tenant_type IN ('individual', 'business', 'group')),
    status varchar(30) NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'active', 'suspended', 'cancelled')),
    default_country_code char(2),
    default_locale varchar(15) NOT NULL DEFAULT 'es',
    default_timezone varchar(60) NOT NULL DEFAULT 'UTC',
    settings jsonb NOT NULL DEFAULT '{}'::jsonb,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE TABLE IF NOT EXISTS plataforma.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email citext NOT NULL UNIQUE,
    display_name varchar(200) NOT NULL,
    first_name varchar(100),
    last_name varchar(100),
    preferred_locale varchar(15),
    timezone varchar(60),
    status varchar(30) NOT NULL DEFAULT 'active',
    identity_provider varchar(50),
    external_identity_id varchar(255),
    last_login_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS plataforma.roles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code varchar(100) NOT NULL UNIQUE,
    name varchar(150) NOT NULL,
    description text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS plataforma.user_tenants (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    user_id uuid NOT NULL REFERENCES plataforma.users(id),
    role_id uuid REFERENCES plataforma.roles(id),
    status varchar(30) NOT NULL DEFAULT 'active',
    permissions_override jsonb NOT NULL DEFAULT '{}'::jsonb,
    joined_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, user_id)
);
CREATE INDEX IF NOT EXISTS user_tenants_tenant_status_idx ON plataforma.user_tenants(tenant_id, status);
CREATE INDEX IF NOT EXISTS user_tenants_user_idx ON plataforma.user_tenants(user_id);
CREATE INDEX IF NOT EXISTS user_tenants_role_idx ON plataforma.user_tenants(role_id);

CREATE TABLE IF NOT EXISTS plataforma.modules (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code varchar(100) NOT NULL UNIQUE,
    name varchar(150) NOT NULL,
    description text,
    category varchar(50) NOT NULL,
    module_type varchar(30) NOT NULL CHECK (module_type IN ('core', 'module', 'agent', 'integration', 'addon')),
    version varchar(30) NOT NULL DEFAULT '1.0.0',
    requires_company boolean NOT NULL DEFAULT false,
    requires_country boolean NOT NULL DEFAULT false,
    requires_subscription boolean NOT NULL DEFAULT false,
    supported_countries jsonb NOT NULL DEFAULT '[]'::jsonb,
    configuration_schema jsonb NOT NULL DEFAULT '{}'::jsonb,
    onboarding_schema jsonb NOT NULL DEFAULT '{}'::jsonb,
    status varchar(30) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'active', 'deprecated')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS plataforma.tenant_modules (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    module_id uuid NOT NULL REFERENCES plataforma.modules(id),
    status varchar(30) NOT NULL DEFAULT 'selected'
        CHECK (status IN ('selected', 'provisioning', 'active', 'suspended', 'cancelled')),
    configuration jsonb NOT NULL DEFAULT '{}'::jsonb,
    limits jsonb NOT NULL DEFAULT '{}'::jsonb,
    activated_at timestamptz,
    expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, module_id)
);
CREATE INDEX IF NOT EXISTS tenant_modules_tenant_status_idx ON plataforma.tenant_modules(tenant_id, status);
CREATE INDEX IF NOT EXISTS tenant_modules_module_idx ON plataforma.tenant_modules(module_id);

CREATE TABLE IF NOT EXISTS auditoria.events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid REFERENCES plataforma.tenants(id),
    actor_user_id uuid REFERENCES plataforma.users(id),
    module_code varchar(100) NOT NULL,
    entity_type varchar(100) NOT NULL,
    entity_id uuid,
    action varchar(100) NOT NULL,
    correlation_id uuid,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS events_tenant_created_idx ON auditoria.events(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS events_actor_idx ON auditoria.events(actor_user_id);

DROP TRIGGER IF EXISTS tenants_set_updated_at ON plataforma.tenants;
CREATE TRIGGER tenants_set_updated_at BEFORE UPDATE ON plataforma.tenants FOR EACH ROW EXECUTE FUNCTION plataforma.set_updated_at();
DROP TRIGGER IF EXISTS users_set_updated_at ON plataforma.users;
CREATE TRIGGER users_set_updated_at BEFORE UPDATE ON plataforma.users FOR EACH ROW EXECUTE FUNCTION plataforma.set_updated_at();
DROP TRIGGER IF EXISTS roles_set_updated_at ON plataforma.roles;
CREATE TRIGGER roles_set_updated_at BEFORE UPDATE ON plataforma.roles FOR EACH ROW EXECUTE FUNCTION plataforma.set_updated_at();
DROP TRIGGER IF EXISTS user_tenants_set_updated_at ON plataforma.user_tenants;
CREATE TRIGGER user_tenants_set_updated_at BEFORE UPDATE ON plataforma.user_tenants FOR EACH ROW EXECUTE FUNCTION plataforma.set_updated_at();
DROP TRIGGER IF EXISTS modules_set_updated_at ON plataforma.modules;
CREATE TRIGGER modules_set_updated_at BEFORE UPDATE ON plataforma.modules FOR EACH ROW EXECUTE FUNCTION plataforma.set_updated_at();
DROP TRIGGER IF EXISTS tenant_modules_set_updated_at ON plataforma.tenant_modules;
CREATE TRIGGER tenant_modules_set_updated_at BEFORE UPDATE ON plataforma.tenant_modules FOR EACH ROW EXECUTE FUNCTION plataforma.set_updated_at();
