-- Solo controles conocidos de Uonify; nunca URLs ni acciones arbitrarias del modelo.
CREATE FUNCTION uony_connection_actions_valid(actions jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN jsonb_typeof(actions) <> 'array' THEN false ELSE
        jsonb_array_length(actions) <= 4
        AND actions <@ '[{"provider":"amazon","action":"manage"},{"provider":"cloud","action":"manage"},{"provider":"drive","action":"manage"},{"provider":"blender","action":"manage"}]'::jsonb
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(actions) AS entry
            WHERE entry NOT IN ('{"provider":"amazon","action":"manage"}'::jsonb,
                '{"provider":"cloud","action":"manage"}'::jsonb,
                '{"provider":"drive","action":"manage"}'::jsonb,
                '{"provider":"blender","action":"manage"}'::jsonb))
        AND jsonb_array_length(actions) = (SELECT count(DISTINCT entry) FROM jsonb_array_elements(actions) AS entry)
    END;
$$;
ALTER TABLE uony_requests DROP CONSTRAINT uony_connection_actions_allowed;
ALTER TABLE uony_requests ADD CONSTRAINT uony_connection_actions_allowed
    CHECK (uony_connection_actions_valid(connection_actions));

ALTER TABLE uony_requests ADD COLUMN conversation_form jsonb;
CREATE FUNCTION uony_conversation_form_valid(form jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE field jsonb; seen text[] := '{}'; option jsonb;
BEGIN
    IF form IS NULL THEN RETURN true; END IF;
    IF jsonb_typeof(form) <> 'object' OR NOT form ?& ARRAY['id','title','fields']
        OR form - ARRAY['id','title','fields'] <> '{}'::jsonb THEN RETURN false; END IF;
    IF jsonb_typeof(form->'id') <> 'string'
        OR form->>'id' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        OR jsonb_typeof(form->'title') <> 'string' OR length(form->>'title') NOT BETWEEN 1 AND 120
        OR jsonb_typeof(form->'fields') <> 'array' THEN RETURN false; END IF;
    IF jsonb_array_length(form->'fields') NOT BETWEEN 1 AND 8 THEN RETURN false; END IF;
    FOR field IN SELECT * FROM jsonb_array_elements(form->'fields') LOOP
        IF jsonb_typeof(field) <> 'object' OR NOT field ?& ARRAY['id','label','type','required']
            OR field - ARRAY['id','label','type','required','options','value'] <> '{}'::jsonb THEN RETURN false; END IF;
        IF jsonb_typeof(field->'id') <> 'string' OR length(field->>'id') > 64
            OR field->>'id' !~ '^[a-zA-Z][a-zA-Z0-9_-]*$' OR field->>'id' IN ('prototype','constructor','__proto__')
            OR field->>'id' = ANY(seen) THEN RETURN false; END IF;
        seen := array_append(seen, field->>'id');
        IF jsonb_typeof(field->'label') <> 'string' OR length(field->>'label') NOT BETWEEN 1 AND 100
            OR jsonb_typeof(field->'type') <> 'string' OR field->>'type' NOT IN ('text','textarea','select') OR jsonb_typeof(field->'required') <> 'boolean'
            THEN RETURN false; END IF;
        IF field ? 'value' AND (jsonb_typeof(field->'value') <> 'string' OR length(field->>'value') > 3000) THEN RETURN false; END IF;
        IF field->>'type' = 'select' THEN
            IF NOT field ? 'options' OR jsonb_typeof(field->'options') <> 'array' THEN RETURN false; END IF;
            IF jsonb_array_length(field->'options') NOT BETWEEN 1 AND 20 THEN RETURN false; END IF;
            FOR option IN SELECT * FROM jsonb_array_elements(field->'options') LOOP
                IF jsonb_typeof(option) <> 'string' OR length(option #>> '{}') NOT BETWEEN 1 AND 160 THEN RETURN false; END IF;
            END LOOP;
            IF jsonb_array_length(field->'options') <> (SELECT count(DISTINCT val) FROM jsonb_array_elements(field->'options') AS val)
                THEN RETURN false; END IF;
            IF field ? 'value' AND NOT field->'options' @> jsonb_build_array(field->'value') THEN RETURN false; END IF;
        ELSIF field ? 'options' THEN RETURN false;
        END IF;
    END LOOP;
    RETURN true;
END;
$$;
ALTER TABLE uony_requests ADD CONSTRAINT uony_conversation_form_allowed
    CHECK (uony_conversation_form_valid(conversation_form)
        AND (conversation_form IS NULL OR conversation_form->>'id' = request_id::text));
