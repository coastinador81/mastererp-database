-- Preserve the exact creation request scope while live product/intake links evolve.
-- NULL identifies rows created before this migration; their origin is unknown.
ALTER TABLE uony_assignments ADD COLUMN origin_scope jsonb;
ALTER TABLE uony_assignments ADD CONSTRAINT uony_assignment_origin_scope_shape
    CHECK (origin_scope IS NULL OR
        (jsonb_typeof(origin_scope)='object'
         AND origin_scope ? 'productId' AND origin_scope ? 'intakeId'
         AND origin_scope - 'productId' - 'intakeId' = '{}'::jsonb));

CREATE FUNCTION immutable_uony_assignment_origin_scope() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.origin_scope IS DISTINCT FROM OLD.origin_scope THEN
        RAISE EXCEPTION 'uony assignment origin scope is immutable';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER immutable_uony_assignment_origin_scope
    BEFORE UPDATE ON uony_assignments FOR EACH ROW
    EXECUTE FUNCTION immutable_uony_assignment_origin_scope();
