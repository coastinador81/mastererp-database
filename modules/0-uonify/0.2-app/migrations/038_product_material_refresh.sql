-- An authorized source replacement retains the exact previous dossier and source versions.
CREATE TABLE product_material_refreshes (
    user_id uuid NOT NULL REFERENCES users(id),
    request_id uuid NOT NULL,
    job_id uuid NOT NULL REFERENCES product_material_jobs(id) ON DELETE CASCADE,
    product_id uuid NOT NULL,
    revision integer NOT NULL,
    google_subject text NOT NULL,
    payload_hash text NOT NULL,
    owner_authorization jsonb NOT NULL,
    result_before jsonb NOT NULL,
    manifest jsonb NOT NULL,
    summary jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(user_id, request_id),
    FOREIGN KEY(user_id, product_id) REFERENCES products(user_id, id) ON DELETE CASCADE
);
CREATE INDEX product_material_refreshes_job ON product_material_refreshes(job_id, created_at);
