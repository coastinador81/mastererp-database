-- Preserve immutable migration 092 and add the pre-start authority guard.
CREATE OR REPLACE FUNCTION creative_craft_attempt_authority_append_only()
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
    IF TG_OP='UPDATE' AND OLD.provider_started_at IS NULL
       AND NEW.provider_started_at IS NOT NULL
       AND OLD.craft_authority_bound_at IS NULL
       AND EXISTS (SELECT 1 FROM creative_execution_steps s
           JOIN creative_execution_jobs j
             ON j.user_id=s.user_id AND j.id=s.job_id
           WHERE s.user_id=NEW.user_id AND s.job_id=NEW.job_id
             AND s.step_id=NEW.step_id AND s.kind='craft'
             AND coalesce((j.graph_snapshot->>'schemaVersion')::integer,1)>=2)
    THEN
        RAISE EXCEPTION 'craft authority must predate provider start';
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
