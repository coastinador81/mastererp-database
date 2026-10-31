BEGIN;

DO $$
DECLARE
    table_count integer;
    v_user_id uuid;
    individual_tenant_id uuid;
    business_tenant_id uuid;
    video_module_id uuid;
    finance_module_id uuid;
    company_id uuid;
    index_name text;
BEGIN
    SELECT count(*) INTO table_count
    FROM information_schema.tables
    WHERE table_type = 'BASE TABLE'
      AND table_schema IN ('plataforma', 'organizacion', 'auditoria');
    IF table_count <> 13 THEN
        RAISE EXCEPTION 'Expected 13 tables, found %', table_count;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'plataforma')
       OR NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'organizacion')
       OR NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'auditoria') THEN
        RAISE EXCEPTION 'Required schemas are missing';
    END IF;

    SELECT id INTO video_module_id FROM plataforma.modules WHERE code = 'video.creation';
    SELECT id INTO finance_module_id FROM plataforma.modules WHERE code = 'erp.finance';
    IF video_module_id IS NULL OR finance_module_id IS NULL THEN
        RAISE EXCEPTION 'Module catalogue seed is incomplete';
    END IF;

    INSERT INTO plataforma.users (email, display_name)
    VALUES ('onboarding-test@example.invalid', 'Onboarding Test')
    RETURNING id INTO v_user_id;
    INSERT INTO plataforma.tenants (code, slug, name, tenant_type, status)
    VALUES ('test-individual', 'test-individual', 'Individual Test', 'individual', 'active')
    RETURNING id INTO individual_tenant_id;
    INSERT INTO plataforma.tenants (code, slug, name, tenant_type, status)
    VALUES ('test-business', 'test-business', 'Business Test', 'business', 'active')
    RETURNING id INTO business_tenant_id;

    INSERT INTO plataforma.user_tenants (tenant_id, user_id, status)
    VALUES (individual_tenant_id, v_user_id, 'active'), (business_tenant_id, v_user_id, 'active');
    INSERT INTO plataforma.tenant_modules (tenant_id, module_id, status, activated_at)
    VALUES (individual_tenant_id, video_module_id, 'active', now()),
           (business_tenant_id, finance_module_id, 'active', now());
    INSERT INTO organizacion.companies (tenant_id, legal_name, country_code, base_currency_code, timezone)
    VALUES (business_tenant_id, 'Business Test Legal', 'US', 'USD', 'UTC')
    RETURNING id INTO company_id;
    INSERT INTO organizacion.branches (tenant_id, company_id, code, name, branch_type, country_code)
    VALUES (business_tenant_id, company_id, 'HQ', 'Headquarters', 'office', 'US');

    IF (SELECT count(*) FROM plataforma.user_tenants WHERE user_id = v_user_id) <> 2 THEN
        RAISE EXCEPTION 'A user must belong to two tenants';
    END IF;
    IF EXISTS (SELECT 1 FROM organizacion.companies WHERE tenant_id = individual_tenant_id) THEN
        RAISE EXCEPTION 'Individual tenant must not need a company';
    END IF;

    FOREACH index_name IN ARRAY ARRAY[
        'user_tenants_tenant_status_idx', 'tenant_modules_tenant_status_idx',
        'onboarding_sessions_tenant_status_idx', 'companies_tenant_status_idx',
        'branches_tenant_company_idx', 'events_tenant_created_idx'
    ] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = index_name) THEN
            RAISE EXCEPTION 'Missing required index %', index_name;
        END IF;
    END LOOP;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'plataforma.tenants'::regclass AND contype = 'c'
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'plataforma.modules'::regclass AND contype = 'c'
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'plataforma.tenant_modules'::regclass AND contype = 'c'
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'plataforma.onboarding_sessions'::regclass AND contype = 'c'
    ) THEN
        RAISE EXCEPTION 'Required status constraints are missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'organizacion.branches'::regclass AND contype = 'f'
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'plataforma.user_tenants'::regclass AND contype = 'u'
    ) THEN
        RAISE EXCEPTION 'Required foreign key or uniqueness constraint is missing';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name LIKE 'uonify_%') THEN
        RAISE EXCEPTION 'Uonify history tables must not exist';
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'auditoria' AND table_name = 'events'
          AND column_name IN ('prompt', 'response', 'message', 'content', 'audio', 'conversation')
    ) THEN
        RAISE EXCEPTION 'Audit event contains prohibited content columns';
    END IF;
END;
$$;

ROLLBACK;
