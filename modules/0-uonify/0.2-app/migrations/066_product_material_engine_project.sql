-- Pin provider and billing project at admission. Existing jobs have no known
-- original project and must never silently adopt the customer's current one.
ALTER TABLE product_material_jobs
    ADD COLUMN engine text NOT NULL DEFAULT 'classic'
        CHECK (engine IN ('classic', 'adk')),
    ADD COLUMN project_id text;

CREATE INDEX product_material_jobs_ready_engine
    ON product_material_jobs(engine, updated_at, created_at, id)
    WHERE status='queued';
