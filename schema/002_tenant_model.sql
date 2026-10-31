-- Modelo idempotente. Tenant es la unidad de aislamiento de datos.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS plataforma;
CREATE SCHEMA IF NOT EXISTS catalogo;
CREATE SCHEMA IF NOT EXISTS comercio;
CREATE SCHEMA IF NOT EXISTS personas;
CREATE SCHEMA IF NOT EXISTS agentes;

CREATE TABLE IF NOT EXISTS plataforma.tenants (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    slug text NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS plataforma.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email text NOT NULL UNIQUE,
    display_name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS plataforma.roles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS plataforma.user_tenants (
    user_id uuid NOT NULL REFERENCES plataforma.users(id) ON DELETE CASCADE,
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id) ON DELETE CASCADE,
    role_id uuid NOT NULL REFERENCES plataforma.roles(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, tenant_id)
);
CREATE INDEX IF NOT EXISTS user_tenants_tenant_idx ON plataforma.user_tenants(tenant_id, role_id);

CREATE TABLE IF NOT EXISTS plataforma.modules (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS plataforma.tenant_modules (
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id) ON DELETE CASCADE,
    module_id uuid NOT NULL REFERENCES plataforma.modules(id) ON DELETE CASCADE,
    enabled boolean NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, module_id)
);

CREATE TABLE IF NOT EXISTS plataforma.audit_log (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    actor_user_id uuid REFERENCES plataforma.users(id),
    action text NOT NULL,
    entity_type text NOT NULL,
    entity_id uuid,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_log_tenant_created_idx ON plataforma.audit_log(tenant_id, created_at DESC);

CREATE TABLE IF NOT EXISTS catalogo.productos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    sku text NOT NULL,
    nombre text NOT NULL,
    precio_centavos integer NOT NULL CHECK (precio_centavos >= 0),
    categoria text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, sku)
);
CREATE INDEX IF NOT EXISTS productos_tenant_nombre_idx ON catalogo.productos(tenant_id, nombre);

CREATE TABLE IF NOT EXISTS catalogo.inventario (
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    sku text NOT NULL,
    cantidad integer NOT NULL DEFAULT 0 CHECK (cantidad >= 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, sku)
);

CREATE TABLE IF NOT EXISTS comercio.paginas (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL UNIQUE REFERENCES plataforma.tenants(id),
    host text NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS personas.empleados (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    nombre text NOT NULL,
    puesto text NOT NULL,
    sucursal text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS empleados_tenant_nombre_idx ON personas.empleados(tenant_id, nombre);

CREATE TABLE IF NOT EXISTS agentes.uonify_conversations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    user_id uuid REFERENCES plataforma.users(id),
    title text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS uonify_conversations_tenant_idx ON agentes.uonify_conversations(tenant_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS agentes.uonify_messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    conversation_id uuid NOT NULL REFERENCES agentes.uonify_conversations(id) ON DELETE CASCADE,
    sender text NOT NULL CHECK (sender IN ('user', 'assistant', 'tool')),
    content jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS uonify_messages_conversation_idx ON agentes.uonify_messages(tenant_id, conversation_id, created_at);

CREATE TABLE IF NOT EXISTS agentes.uonify_contexts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    conversation_id uuid REFERENCES agentes.uonify_conversations(id) ON DELETE CASCADE,
    context_key text NOT NULL,
    value jsonb NOT NULL,
    expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, conversation_id, context_key)
);

CREATE TABLE IF NOT EXISTS agentes.uonify_tool_executions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    conversation_id uuid REFERENCES agentes.uonify_conversations(id) ON DELETE SET NULL,
    tool_name text NOT NULL,
    status text NOT NULL CHECK (status IN ('requested', 'approved', 'completed', 'failed')),
    request_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    response_payload jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz
);
CREATE INDEX IF NOT EXISTS uonify_tools_tenant_status_idx ON agentes.uonify_tool_executions(tenant_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS comercio.digital_sales_product_drafts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    created_by_user_id uuid REFERENCES plataforma.users(id),
    status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'review', 'published', 'discarded')),
    name text NOT NULL,
    sku text,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS digital_sales_drafts_tenant_status_idx ON comercio.digital_sales_product_drafts(tenant_id, status, updated_at DESC);

CREATE TABLE IF NOT EXISTS comercio.digital_sales_product_draft_assets (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    draft_id uuid NOT NULL REFERENCES comercio.digital_sales_product_drafts(id) ON DELETE CASCADE,
    asset_url text NOT NULL,
    asset_type text NOT NULL,
    position integer NOT NULL DEFAULT 0 CHECK (position >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, draft_id, asset_url)
);
