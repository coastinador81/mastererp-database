-- Entidad «GPSR por marca» + historial fechado (hilo Producto/Catálogo, Reglamento UE 2023/988).
-- Perfil GPSR reutilizable por marca; los productos lo heredan (resolve_product_gpsr). El historial
-- append-only cubre la trazabilidad (Legal §4.3/§4.4). Mismo patrón que products/product_revisions.
CREATE TABLE brand_gpsr (
    user_id uuid NOT NULL REFERENCES users(id),
    id uuid NOT NULL,
    brand text NOT NULL,
    data jsonb NOT NULL,
    revision integer NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    PRIMARY KEY(user_id, id)
);
CREATE UNIQUE INDEX brand_gpsr_active_brand ON brand_gpsr(user_id, lower(brand)) WHERE deleted_at IS NULL;
CREATE TABLE brand_gpsr_revisions (
    user_id uuid NOT NULL,
    brand_gpsr_id uuid NOT NULL,
    revision integer NOT NULL,
    data jsonb NOT NULL,
    source text NOT NULL,
    changed_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(user_id, brand_gpsr_id, revision),
    FOREIGN KEY(user_id, brand_gpsr_id) REFERENCES brand_gpsr(user_id, id)
);
CREATE INDEX brand_gpsr_revisions_timeline ON brand_gpsr_revisions(user_id, brand_gpsr_id, created_at);
