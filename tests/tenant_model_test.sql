-- Pruebas estructurales para ejecutar contra una base temporal.
DO $$
BEGIN
    IF to_regclass('plataforma.tenants') IS NULL OR to_regclass('plataforma.user_tenants') IS NULL THEN
        RAISE EXCEPTION 'Tenant model is incomplete';
    END IF;
    IF to_regclass('agentes.uonify_conversations') IS NULL OR to_regclass('comercio.digital_sales_product_drafts') IS NULL THEN
        RAISE EXCEPTION 'Required planned domains are missing';
    END IF;
END $$;
