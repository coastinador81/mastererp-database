-- A job belongs to an assignment only when its authorized start and this
-- relation commit together. Historical product jobs are never inferred.
ALTER TABLE product_material_jobs
    ADD CONSTRAINT product_material_jobs_assignment_scope
    UNIQUE (user_id,id,product_id,google_subject);

CREATE TABLE uony_assignment_material_jobs (
    user_id uuid NOT NULL,
    assignment_id uuid NOT NULL,
    google_subject text NOT NULL,
    product_id uuid NOT NULL,
    material_job_id uuid NOT NULL,
    origin_request_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,material_job_id),
    UNIQUE (user_id,origin_request_id),
    FOREIGN KEY (user_id,assignment_id,google_subject)
        REFERENCES uony_assignments(user_id,id,google_subject) ON DELETE CASCADE,
    FOREIGN KEY (user_id,material_job_id,product_id,google_subject)
        REFERENCES product_material_jobs(user_id,id,product_id,google_subject) ON DELETE CASCADE
);
CREATE INDEX uony_assignment_material_jobs_recent
    ON uony_assignment_material_jobs(user_id,assignment_id,created_at DESC,material_job_id DESC);
