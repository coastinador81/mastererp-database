-- Preserve the applied migration 094; append its subsequent guards.
CREATE OR REPLACE FUNCTION creative_attempt_materializations_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.craft_input_materializations IS NOT NULL OR
           NEW.craft_input_materializations_sha256 IS NOT NULL THEN
            RAISE EXCEPTION 'craft input materializations require a live attempt';
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.craft_authority_bound_at IS NULL AND
       NEW.craft_authority_bound_at IS NOT NULL AND
       EXISTS (SELECT 1 FROM jsonb_array_elements(
           COALESCE(NEW.craft_resolved_job_snapshot->'inputs', '[]'::jsonb)) item
           WHERE item->>'kind' = 'image_sequence') AND
       OLD.craft_input_materializations IS NULL THEN
        RAISE EXCEPTION 'image sequence materializations must predate craft authority';
    END IF;
    IF OLD.craft_input_materializations IS NOT NULL AND
       (NEW.craft_input_materializations IS DISTINCT FROM OLD.craft_input_materializations
        OR NEW.craft_input_materializations_sha256 IS DISTINCT FROM
           OLD.craft_input_materializations_sha256) THEN
        RAISE EXCEPTION 'craft input materializations are immutable';
    END IF;
    IF OLD.craft_input_materializations IS NULL AND
       NEW.craft_input_materializations IS NOT NULL AND
       (OLD.provider_started_at IS NOT NULL
        OR OLD.craft_authority_bound_at IS NOT NULL
        OR OLD.status <> 'running') THEN
        RAISE EXCEPTION 'craft input materializations must precede authority and provider';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER creative_attempt_materializations_immutable_trigger ON creative_execution_attempts;
CREATE TRIGGER creative_attempt_materializations_immutable_trigger
    BEFORE INSERT OR UPDATE ON creative_execution_attempts
    FOR EACH ROW EXECUTE FUNCTION creative_attempt_materializations_immutable();
