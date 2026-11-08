-- Immutable, pre-provider receipts for worker-local image-sequence mounts.

ALTER TABLE creative_execution_attempts
    ADD COLUMN craft_input_materializations jsonb,
    ADD COLUMN craft_input_materializations_sha256 text,
    ADD CONSTRAINT creative_attempt_craft_materializations_pair CHECK (
        (craft_input_materializations IS NULL
         AND craft_input_materializations_sha256 IS NULL)
        OR (jsonb_typeof(craft_input_materializations) = 'array'
            AND craft_input_materializations_sha256 ~ '^[0-9a-f]{64}$'));

CREATE OR REPLACE FUNCTION creative_attempt_materializations_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
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

CREATE TRIGGER creative_attempt_materializations_immutable_trigger
    BEFORE UPDATE ON creative_execution_attempts
    FOR EACH ROW EXECUTE FUNCTION creative_attempt_materializations_immutable();
