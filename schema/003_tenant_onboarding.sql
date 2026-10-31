CREATE TABLE IF NOT EXISTS plataforma.onboarding_flows (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code varchar(100) NOT NULL UNIQUE,
    name varchar(150) NOT NULL,
    tenant_type varchar(30),
    country_code char(2),
    module_id uuid REFERENCES plataforma.modules(id),
    version varchar(30) NOT NULL DEFAULT '1.0.0',
    status varchar(30) NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS onboarding_flows_module_idx ON plataforma.onboarding_flows(module_id);

CREATE TABLE IF NOT EXISTS plataforma.onboarding_flow_steps (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    flow_id uuid NOT NULL REFERENCES plataforma.onboarding_flows(id),
    step_code varchar(100) NOT NULL,
    title varchar(150) NOT NULL,
    position integer NOT NULL,
    is_required boolean NOT NULL DEFAULT true,
    condition_rules jsonb NOT NULL DEFAULT '{}'::jsonb,
    input_schema jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (flow_id, step_code),
    UNIQUE (flow_id, position)
);
CREATE INDEX IF NOT EXISTS onboarding_flow_steps_flow_idx ON plataforma.onboarding_flow_steps(flow_id);

CREATE TABLE IF NOT EXISTS plataforma.onboarding_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid REFERENCES plataforma.tenants(id),
    initiated_by_user_id uuid NOT NULL REFERENCES plataforma.users(id),
    status varchar(30) NOT NULL DEFAULT 'started'
        CHECK (status IN ('started', 'in_progress', 'completed', 'abandoned')),
    current_step_code varchar(100),
    selected_module_codes jsonb NOT NULL DEFAULT '[]'::jsonb,
    context jsonb NOT NULL DEFAULT '{}'::jsonb,
    started_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS onboarding_sessions_tenant_status_idx ON plataforma.onboarding_sessions(tenant_id, status);
CREATE INDEX IF NOT EXISTS onboarding_sessions_user_idx ON plataforma.onboarding_sessions(initiated_by_user_id);

CREATE TABLE IF NOT EXISTS plataforma.onboarding_step_responses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id uuid NOT NULL REFERENCES plataforma.onboarding_sessions(id),
    step_id uuid NOT NULL REFERENCES plataforma.onboarding_flow_steps(id),
    response_data jsonb NOT NULL DEFAULT '{}'::jsonb,
    status varchar(30) NOT NULL DEFAULT 'draft',
    validated_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (session_id, step_id)
);
CREATE INDEX IF NOT EXISTS onboarding_step_responses_session_idx ON plataforma.onboarding_step_responses(session_id);
CREATE INDEX IF NOT EXISTS onboarding_step_responses_step_idx ON plataforma.onboarding_step_responses(step_id);

CREATE TABLE IF NOT EXISTS organizacion.companies (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    legal_name varchar(250) NOT NULL,
    trade_name varchar(250),
    country_code char(2) NOT NULL,
    tax_identifier varchar(100),
    base_currency_code char(3) NOT NULL,
    secondary_currency_codes jsonb NOT NULL DEFAULT '[]'::jsonb,
    timezone varchar(60) NOT NULL,
    status varchar(30) NOT NULL DEFAULT 'active',
    settings jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS companies_tenant_status_idx ON organizacion.companies(tenant_id, status);

CREATE TABLE IF NOT EXISTS organizacion.branches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES plataforma.tenants(id),
    company_id uuid NOT NULL REFERENCES organizacion.companies(id),
    code varchar(50) NOT NULL,
    name varchar(200) NOT NULL,
    branch_type varchar(30) NOT NULL,
    country_code char(2) NOT NULL,
    address jsonb NOT NULL DEFAULT '{}'::jsonb,
    status varchar(30) NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (company_id, code)
);
CREATE INDEX IF NOT EXISTS branches_tenant_company_idx ON organizacion.branches(tenant_id, company_id);

DROP TRIGGER IF EXISTS onboarding_flows_set_updated_at ON plataforma.onboarding_flows;
CREATE TRIGGER onboarding_flows_set_updated_at BEFORE UPDATE ON plataforma.onboarding_flows FOR EACH ROW EXECUTE FUNCTION plataforma.set_updated_at();
DROP TRIGGER IF EXISTS onboarding_flow_steps_set_updated_at ON plataforma.onboarding_flow_steps;
CREATE TRIGGER onboarding_flow_steps_set_updated_at BEFORE UPDATE ON plataforma.onboarding_flow_steps FOR EACH ROW EXECUTE FUNCTION plataforma.set_updated_at();
DROP TRIGGER IF EXISTS onboarding_sessions_set_updated_at ON plataforma.onboarding_sessions;
CREATE TRIGGER onboarding_sessions_set_updated_at BEFORE UPDATE ON plataforma.onboarding_sessions FOR EACH ROW EXECUTE FUNCTION plataforma.set_updated_at();
DROP TRIGGER IF EXISTS onboarding_step_responses_set_updated_at ON plataforma.onboarding_step_responses;
CREATE TRIGGER onboarding_step_responses_set_updated_at BEFORE UPDATE ON plataforma.onboarding_step_responses FOR EACH ROW EXECUTE FUNCTION plataforma.set_updated_at();
DROP TRIGGER IF EXISTS companies_set_updated_at ON organizacion.companies;
CREATE TRIGGER companies_set_updated_at BEFORE UPDATE ON organizacion.companies FOR EACH ROW EXECUTE FUNCTION plataforma.set_updated_at();
DROP TRIGGER IF EXISTS branches_set_updated_at ON organizacion.branches;
CREATE TRIGGER branches_set_updated_at BEFORE UPDATE ON organizacion.branches FOR EACH ROW EXECUTE FUNCTION plataforma.set_updated_at();
