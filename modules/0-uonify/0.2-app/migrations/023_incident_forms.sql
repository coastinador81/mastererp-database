-- Formularios de incidencia emitidos por servidor. La guía existente conserva su validación.
ALTER FUNCTION uony_conversation_form_valid(jsonb) RENAME TO uony_product_conversation_form_valid;
CREATE FUNCTION uony_conversation_form_valid(form jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE context jsonb; field jsonb; seen text[] := '{}'; option jsonb;
BEGIN
    IF form IS NULL OR form->'context'->>'kind' IS DISTINCT FROM 'product_incident' THEN
        RETURN uony_product_conversation_form_valid(form);
    END IF;
    IF jsonb_typeof(form) <> 'object' OR NOT form ?& ARRAY['id','title','fields','context']
       OR form - ARRAY['id','title','fields','context','review','submitLabel'] <> '{}'::jsonb
       OR form->>'id' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR length(form->>'title') NOT BETWEEN 1 AND 120 OR jsonb_typeof(form->'fields') <> 'array'
       OR jsonb_array_length(form->'fields') NOT BETWEEN 1 AND 8 THEN RETURN false; END IF;
    context := form->'context';
    IF jsonb_typeof(context) <> 'object' OR NOT context ?& ARRAY['kind','incidentId','revision','step']
       OR context->>'revision' !~ '^[1-9][0-9]*$'
       OR context->>'step' NOT IN ('edit','review','waiting','pick') THEN RETURN false; END IF;
    FOR field IN SELECT * FROM jsonb_array_elements(form->'fields') LOOP
        IF jsonb_typeof(field) <> 'object' OR NOT field ?& ARRAY['id','label','type','required']
           OR field - ARRAY['id','label','type','required','options','value','closed','validation','hint'] <> '{}'::jsonb
           OR field->>'id' !~ '^[a-zA-Z][a-zA-Z0-9_-]{0,63}$'
           OR field->>'id' IN ('prototype','constructor','__proto__') OR field->>'id' = ANY(seen)
           OR length(field->>'label') NOT BETWEEN 1 AND 100
           OR field->>'type' NOT IN ('text','textarea','select')
           OR jsonb_typeof(field->'required') <> 'boolean' THEN RETURN false; END IF;
        seen := array_append(seen, field->>'id');
        IF field ? 'value' AND (jsonb_typeof(field->'value') <> 'string' OR length(field->>'value') > 3000) THEN RETURN false; END IF;
        IF field ? 'closed' AND jsonb_typeof(field->'closed') <> 'boolean' THEN RETURN false; END IF;
        IF field ? 'hint' AND (jsonb_typeof(field->'hint') <> 'string' OR length(field->>'hint') > 600) THEN RETURN false; END IF;
        IF field ? 'validation' AND jsonb_typeof(field->'validation') <> 'object' THEN RETURN false; END IF;
        IF field->>'type' = 'select' THEN
            IF jsonb_typeof(field->'options') <> 'array' OR jsonb_array_length(field->'options') NOT BETWEEN 1 AND 500 THEN RETURN false; END IF;
            FOR option IN SELECT * FROM jsonb_array_elements(field->'options') LOOP
                IF jsonb_typeof(option) <> 'string' OR length(option #>> '{}') NOT BETWEEN 1 AND 160 THEN RETURN false; END IF;
            END LOOP;
            IF jsonb_array_length(field->'options') <> (SELECT count(DISTINCT item) FROM jsonb_array_elements(field->'options') item) THEN RETURN false; END IF;
        END IF;
    END LOOP;
    IF form ? 'review' AND (jsonb_typeof(form->'review') <> 'array' OR jsonb_array_length(form->'review') > 100) THEN RETURN false; END IF;
    RETURN true;
END;
$$;
ALTER TABLE uony_requests DROP CONSTRAINT uony_conversation_form_allowed;
ALTER TABLE uony_requests ADD CONSTRAINT uony_conversation_form_allowed
    CHECK (uony_conversation_form_valid(conversation_form)
        AND (conversation_form IS NULL OR conversation_form->>'id' = request_id::text));
