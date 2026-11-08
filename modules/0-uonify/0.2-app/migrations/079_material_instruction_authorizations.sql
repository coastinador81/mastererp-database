-- A customer's explicit chat instruction can start the existing material queue
-- before a product/SKU exists. The selected intake is the alternative owner.
ALTER TABLE product_material_jobs
    ALTER COLUMN product_id DROP NOT NULL,
    ADD COLUMN intake_id uuid,
    ADD CONSTRAINT product_material_jobs_intake_owner
        FOREIGN KEY (user_id,intake_id) REFERENCES uony_product_intakes(user_id,id),
    ADD CONSTRAINT product_material_jobs_subject_owner
        CHECK ((product_id IS NOT NULL) <> (intake_id IS NOT NULL)),
    ADD CONSTRAINT product_material_jobs_intake_scope
        UNIQUE (user_id,id,intake_id,google_subject);

CREATE INDEX product_material_jobs_intake_recent
    ON product_material_jobs(user_id,intake_id,created_at DESC,id DESC)
    WHERE intake_id IS NOT NULL;
CREATE UNIQUE INDEX product_material_jobs_active_intake
    ON product_material_jobs(user_id,intake_id)
    WHERE intake_id IS NOT NULL AND status IN ('queued','running');

ALTER TABLE uony_assignment_material_jobs
    ALTER COLUMN product_id DROP NOT NULL,
    ADD COLUMN intake_id uuid,
    ADD CONSTRAINT uony_assignment_material_jobs_subject_owner
        CHECK ((product_id IS NOT NULL) <> (intake_id IS NOT NULL)),
    ADD CONSTRAINT uony_assignment_material_jobs_intake_owner
        FOREIGN KEY (user_id,material_job_id,intake_id,google_subject)
        REFERENCES product_material_jobs(user_id,id,intake_id,google_subject);

ALTER TABLE product_material_job_authorizations
    ALTER COLUMN product_id DROP NOT NULL,
    ADD COLUMN intake_id uuid,
    ADD COLUMN conversation_request_id uuid,
    ADD COLUMN conversation_thread_id text,
    ADD COLUMN instruction_text text,
    ADD COLUMN instruction_sha256 text,
    ADD CONSTRAINT product_material_authorizations_intake_owner
        FOREIGN KEY (user_id,job_id,intake_id,google_subject)
        REFERENCES product_material_jobs(user_id,id,intake_id,google_subject),
    ADD CONSTRAINT product_material_authorizations_conversation
        FOREIGN KEY (user_id,conversation_request_id)
        REFERENCES uony_requests(user_id,request_id),
    ADD CONSTRAINT product_material_authorizations_subject_owner
        CHECK ((product_id IS NOT NULL) <> (intake_id IS NOT NULL)),
    ADD CONSTRAINT product_material_authorizations_instruction_sha
        CHECK (instruction_sha256 IS NULL OR instruction_sha256 ~ '^[0-9a-f]{64}$');

-- Replace only the old source-specific checks. Keep the existing digest shape,
-- action/reanalysis and immutable-ledger constraints in place.
DO $$
DECLARE old_check record;
BEGIN
    FOR old_check IN SELECT conname FROM pg_constraint
        WHERE conrelid='product_material_job_authorizations'::regclass
          AND contype='c' AND pg_get_constraintdef(oid) LIKE '%source%'
    LOOP
        EXECUTE format('ALTER TABLE product_material_job_authorizations DROP CONSTRAINT %I',
                       old_check.conname);
    END LOOP;
END $$;

ALTER TABLE product_material_job_authorizations
    ADD CONSTRAINT product_material_authorizations_source_contract CHECK (
        (source='legacy_post_only' AND consent_version IS NULL
            AND consent_text IS NULL AND consent_sha256 IS NULL AND accepted_at IS NULL
            AND conversation_request_id IS NULL AND conversation_thread_id IS NULL
            AND instruction_text IS NULL AND instruction_sha256 IS NULL)
        OR (source='versioned_ui_ack' AND consent_version IS NOT NULL
            AND consent_text IS NOT NULL AND consent_sha256 IS NOT NULL
            AND accepted_at IS NOT NULL AND conversation_request_id IS NULL
            AND conversation_thread_id IS NULL AND instruction_text IS NULL
            AND instruction_sha256 IS NULL)
        OR (source='chat_instruction' AND accepted_at IS NOT NULL
            AND consent_version IS NULL AND consent_text IS NULL AND consent_sha256 IS NULL
            AND conversation_request_id=origin_request_id
            AND conversation_thread_id IS NOT NULL
            AND char_length(instruction_text) BETWEEN 1 AND 3000
            AND instruction_sha256 IS NOT NULL)
    );
