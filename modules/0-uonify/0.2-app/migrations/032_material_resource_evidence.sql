-- Las preguntas de revisión de recursos muestran todas las citas afectadas.
ALTER FUNCTION uony_conversation_form_valid(jsonb) RENAME TO uony_pre_resource_evidence_form_valid;
CREATE FUNCTION uony_conversation_form_valid(form jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE field jsonb; item jsonb; clean_fields jsonb := '[]'::jsonb;
BEGIN
    IF form IS NULL OR form->'context'->>'kind' IS DISTINCT FROM 'drive_analysis' THEN
        RETURN uony_pre_resource_evidence_form_valid(form);
    END IF;
    IF jsonb_typeof(form->'fields') IS DISTINCT FROM 'array' THEN RETURN false; END IF;
    FOR field IN SELECT * FROM jsonb_array_elements(form->'fields') LOOP
        IF field ? 'resourceEvidence' THEN
            IF jsonb_typeof(field->'resourceEvidence') IS DISTINCT FROM 'array'
               OR jsonb_array_length(field->'resourceEvidence') > 5000 THEN RETURN false; END IF;
            FOR item IN SELECT * FROM jsonb_array_elements(field->'resourceEvidence') LOOP
                IF jsonb_typeof(item) IS DISTINCT FROM 'object'
                   OR NOT item ?& ARRAY['sourceName','locator','excerpt']
                   OR item - ARRAY['sourceName','locator','excerpt'] <> '{}'::jsonb
                   OR jsonb_typeof(item->'sourceName') IS DISTINCT FROM 'string'
                   OR jsonb_typeof(item->'locator') IS DISTINCT FROM 'string'
                   OR jsonb_typeof(item->'excerpt') IS DISTINCT FROM 'string'
                   OR length(item->>'sourceName') > 500 OR length(item->>'locator') > 500
                   OR length(item->>'excerpt') > 300 THEN RETURN false; END IF;
            END LOOP;
        END IF;
        clean_fields := clean_fields || jsonb_build_array(field - 'resourceEvidence');
    END LOOP;
    RETURN uony_pre_resource_evidence_form_valid(jsonb_set(form, '{fields}', clean_fields));
END;
$$;
ALTER TABLE uony_requests DROP CONSTRAINT uony_conversation_form_allowed;
ALTER TABLE uony_requests ADD CONSTRAINT uony_conversation_form_allowed
    CHECK (uony_conversation_form_valid(conversation_form)
        AND (conversation_form IS NULL OR conversation_form->>'id' = request_id::text));
