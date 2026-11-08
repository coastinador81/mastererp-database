-- Originales en Drive; propuestas y referencias se conservan por cuenta y revisión.
CREATE TABLE product_material_jobs (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL,
    product_id uuid NOT NULL,
    request_id uuid NOT NULL,
    google_subject text NOT NULL,
    revision integer NOT NULL CHECK (revision > 0),
    folder_id text NOT NULL,
    status text NOT NULL CHECK (status IN ('queued','running','ready','error')),
    result jsonb NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(user_id,request_id),
    FOREIGN KEY(user_id,product_id) REFERENCES products(user_id,id)
);
CREATE INDEX product_material_jobs_product ON product_material_jobs(user_id,product_id,created_at DESC);
CREATE UNIQUE INDEX product_material_jobs_active ON product_material_jobs(user_id,product_id) WHERE status IN ('queued','running');
