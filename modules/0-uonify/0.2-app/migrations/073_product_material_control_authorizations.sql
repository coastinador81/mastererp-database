-- A control that opens another paid analysis block carries its own decision.
-- Existing controls are historical and receive no inferred acceptance.
ALTER TABLE product_material_controls ADD CONSTRAINT product_material_controls_receipt_scope
    UNIQUE (user_id,request_id,job_id,action);

CREATE TABLE product_material_control_authorizations (
    user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    job_id uuid NOT NULL,
    action text NOT NULL CHECK (action IN ('upgrade_readers','repair_evidence')),
    google_subject text NOT NULL,
    product_id uuid NOT NULL,
    revision integer NOT NULL CHECK (revision > 0),
    folder_id text NOT NULL,
    project_id text NOT NULL,
    source text NOT NULL CHECK (source IN ('versioned_ui_ack','legacy_post_only')),
    consent_version text,
    consent_text text,
    consent_sha256 text CHECK (consent_sha256 ~ '^[0-9a-f]{64}$'),
    recorded_at timestamptz NOT NULL DEFAULT now(),
    accepted_at timestamptz,
    PRIMARY KEY (user_id,request_id),
    FOREIGN KEY (user_id,request_id,job_id,action)
        REFERENCES product_material_controls(user_id,request_id,job_id,action),
    FOREIGN KEY (user_id,job_id,product_id,google_subject)
        REFERENCES product_material_jobs(user_id,id,product_id,google_subject),
    CHECK ((source='legacy_post_only' AND consent_version IS NULL
        AND consent_text IS NULL AND consent_sha256 IS NULL AND accepted_at IS NULL)
        OR (source='versioned_ui_ack' AND consent_version IS NOT NULL
        AND consent_text IS NOT NULL AND consent_sha256 IS NOT NULL
        AND accepted_at IS NOT NULL))
);
CREATE TRIGGER account_write_allowed BEFORE INSERT ON product_material_control_authorizations
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();

CREATE FUNCTION immutable_material_control_authorization() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE'
        AND current_setting('uonify.deleting_user',true)=OLD.user_id::text
        AND EXISTS(SELECT 1 FROM users WHERE id=OLD.user_id AND deletion_requested_at IS NOT NULL) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'product_material_control_authorizations are immutable';
END;
$$;
CREATE TRIGGER immutable_material_control_authorization
    BEFORE UPDATE OR DELETE ON product_material_control_authorizations
    FOR EACH ROW EXECUTE FUNCTION immutable_material_control_authorization();
