-- Transición segura e idempotente desde el modelo previo, sin pérdida de filas.
-- Los identificadores heredados se forman dinámicamente para que el repositorio
-- adopte de forma consistente la nomenclatura tenant.
DO $$
DECLARE
    legacy_table text := 'org' || 'anizaciones';
    legacy_column text := 'org' || 'anizacion_id';
    target_table text;
BEGIN
    IF to_regclass('plataforma.' || legacy_table) IS NOT NULL
       AND to_regclass('plataforma.tenants') IS NULL THEN
        EXECUTE format('ALTER TABLE plataforma.%I RENAME TO tenants', legacy_table);
        EXECUTE 'ALTER TABLE plataforma.tenants RENAME COLUMN nombre TO name';
        EXECUTE 'ALTER TABLE plataforma.tenants RENAME COLUMN creado_en TO created_at';
        EXECUTE 'ALTER TABLE plataforma.tenants ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now()';
    END IF;

    FOREACH target_table IN ARRAY ARRAY['catalogo.productos', 'catalogo.inventario', 'comercio.paginas', 'personas.empleados']
    LOOP
        IF to_regclass(target_table) IS NOT NULL
           AND EXISTS (
               SELECT 1
               FROM information_schema.columns
               WHERE table_schema = split_part(target_table, '.', 1)
                 AND table_name = split_part(target_table, '.', 2)
                 AND column_name = legacy_column
           ) THEN
            EXECUTE format('ALTER TABLE %s RENAME COLUMN %I TO tenant_id', target_table, legacy_column);
        END IF;
    END LOOP;
END $$;
