-- Exact Craft authority is bound before provider start. These snapshots are
-- additive and private; they do not enable dispatch, workers or publication.
ALTER TABLE creative_execution_attempts
    ADD COLUMN craft_resolved_job_snapshot jsonb,
    ADD COLUMN craft_job_binding_sha256 text
        CHECK (craft_job_binding_sha256 ~ '^[0-9a-f]{64}$'),
    ADD COLUMN craft_preflight_snapshot jsonb,
    ADD COLUMN craft_preflight_sha256 text
        CHECK (craft_preflight_sha256 ~ '^[0-9a-f]{64}$'),
    ADD COLUMN craft_adapter_plan_snapshot jsonb,
    ADD COLUMN craft_adapter_plan_sha256 text
        CHECK (craft_adapter_plan_sha256 ~ '^[0-9a-f]{64}$'),
    ADD COLUMN craft_capability_matrix_sha256 text
        CHECK (craft_capability_matrix_sha256 ~ '^[0-9a-f]{64}$'),
    ADD COLUMN craft_contract_schema_sha256 text
        CHECK (craft_contract_schema_sha256 ~ '^[0-9a-f]{64}$'),
    ADD COLUMN craft_adapter_compiler_version text,
    ADD COLUMN craft_adapter_source_sha256 text
        CHECK (craft_adapter_source_sha256 ~ '^[0-9a-f]{64}$'),
    ADD COLUMN craft_recipe_sha256 text
        CHECK (craft_recipe_sha256 ~ '^[0-9a-f]{64}$'),
    ADD COLUMN craft_resolved_input_manifest_sha256 text
        CHECK (craft_resolved_input_manifest_sha256 ~ '^[0-9a-f]{64}$'),
    ADD COLUMN craft_authority_bound_at timestamptz,
    ADD CONSTRAINT creative_attempt_craft_authority_complete CHECK (
        (craft_authority_bound_at IS NULL
         AND craft_resolved_job_snapshot IS NULL
         AND craft_job_binding_sha256 IS NULL
         AND craft_preflight_snapshot IS NULL
         AND craft_preflight_sha256 IS NULL
         AND craft_adapter_plan_snapshot IS NULL
         AND craft_adapter_plan_sha256 IS NULL
         AND craft_capability_matrix_sha256 IS NULL
         AND craft_contract_schema_sha256 IS NULL
         AND craft_adapter_compiler_version IS NULL
         AND craft_adapter_source_sha256 IS NULL
         AND craft_recipe_sha256 IS NULL
         AND craft_resolved_input_manifest_sha256 IS NULL)
        OR
        (craft_authority_bound_at IS NOT NULL
         AND jsonb_typeof(craft_resolved_job_snapshot)='object'
         AND craft_job_binding_sha256 IS NOT NULL
         AND jsonb_typeof(craft_preflight_snapshot)='object'
         AND craft_preflight_sha256 IS NOT NULL
         AND jsonb_typeof(craft_adapter_plan_snapshot)='object'
         AND craft_adapter_plan_sha256 IS NOT NULL
         AND craft_capability_matrix_sha256 IS NOT NULL
         AND craft_contract_schema_sha256 IS NOT NULL
         AND length(craft_adapter_compiler_version)>0
         AND craft_adapter_source_sha256 IS NOT NULL
         AND craft_recipe_sha256 IS NOT NULL
         AND craft_resolved_input_manifest_sha256 IS NOT NULL));

CREATE FUNCTION creative_craft_attempt_authority_append_only()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' AND (NEW.provider_started_at IS NOT NULL
                           OR NEW.craft_authority_bound_at IS NOT NULL) THEN
        RAISE EXCEPTION 'craft authority must be appended before provider start';
    END IF;
    IF TG_OP='UPDATE' AND OLD.craft_authority_bound_at IS NOT NULL
       AND (OLD.craft_resolved_job_snapshot,OLD.craft_job_binding_sha256,
            OLD.craft_preflight_snapshot,OLD.craft_preflight_sha256,
            OLD.craft_adapter_plan_snapshot,OLD.craft_adapter_plan_sha256,
            OLD.craft_capability_matrix_sha256,OLD.craft_contract_schema_sha256,
            OLD.craft_adapter_compiler_version,OLD.craft_adapter_source_sha256,
            OLD.craft_recipe_sha256,OLD.craft_resolved_input_manifest_sha256,
            OLD.craft_authority_bound_at)
           IS DISTINCT FROM
           (NEW.craft_resolved_job_snapshot,NEW.craft_job_binding_sha256,
            NEW.craft_preflight_snapshot,NEW.craft_preflight_sha256,
            NEW.craft_adapter_plan_snapshot,NEW.craft_adapter_plan_sha256,
            NEW.craft_capability_matrix_sha256,NEW.craft_contract_schema_sha256,
            NEW.craft_adapter_compiler_version,NEW.craft_adapter_source_sha256,
            NEW.craft_recipe_sha256,NEW.craft_resolved_input_manifest_sha256,
            NEW.craft_authority_bound_at)
    THEN
        RAISE EXCEPTION 'craft attempt authority is append-only';
    END IF;
    IF NEW.provider_started_at IS NOT NULL
       AND EXISTS (SELECT 1 FROM creative_execution_steps s
           JOIN creative_execution_jobs j
             ON j.user_id=s.user_id AND j.id=s.job_id
           WHERE s.user_id=NEW.user_id AND s.job_id=NEW.job_id
             AND s.step_id=NEW.step_id AND s.kind='craft'
             AND coalesce((j.graph_snapshot->>'schemaVersion')::integer,1)>=2)
       AND NEW.craft_authority_bound_at IS NULL
    THEN
        RAISE EXCEPTION 'craft provider start requires bound authority';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER creative_craft_attempt_authority_append_only
    BEFORE INSERT OR UPDATE ON creative_execution_attempts
    FOR EACH ROW EXECUTE FUNCTION creative_craft_attempt_authority_append_only();
