-- La tarjeta de materiales y la revisión son parte persistente del mismo hilo.
ALTER TABLE uony_requests ADD COLUMN material_analysis jsonb;
ALTER TABLE uony_requests ADD COLUMN material_action jsonb;
ALTER TABLE uony_requests ADD CONSTRAINT uony_material_analysis_valid CHECK (
    material_analysis IS NULL OR (
        jsonb_typeof(material_analysis) = 'object'
        AND material_analysis ?& ARRAY['sku','revision']
        AND material_analysis - ARRAY['sku','revision'] = '{}'::jsonb
        AND material_analysis->>'sku' ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$'
        AND jsonb_typeof(material_analysis->'revision') = 'number'
        AND material_analysis->>'revision' ~ '^[1-9][0-9]*$'
    )
);
ALTER FUNCTION uony_conversation_form_valid(jsonb) RENAME TO uony_requirements_conversation_form_valid;
CREATE FUNCTION uony_conversation_form_valid(form jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE context jsonb; proposal jsonb; seen text[] := '{}';
BEGIN
    IF form IS NULL OR form->'context'->>'kind' IS DISTINCT FROM 'drive_analysis' THEN
        RETURN uony_requirements_conversation_form_valid(form);
    END IF;
    context := form->'context';
    IF jsonb_typeof(context) <> 'object'
       OR NOT context ?& ARRAY['kind','sku','revision','section','analysisId','proposalIds']
       OR context - ARRAY['kind','sku','revision','section','analysisId','proposalIds'] <> '{}'::jsonb
       OR context->>'section' <> 'review'
       OR context->>'analysisId' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR jsonb_typeof(context->'proposalIds') <> 'array'
       OR jsonb_array_length(context->'proposalIds') NOT BETWEEN 1 AND 7
       THEN RETURN false; END IF;
    FOR proposal IN SELECT * FROM jsonb_array_elements(context->'proposalIds') LOOP
        IF jsonb_typeof(proposal) <> 'string' OR length(proposal #>> '{}') NOT BETWEEN 1 AND 100
           OR proposal #>> '{}' = ANY(seen) THEN RETURN false; END IF;
        seen := array_append(seen, proposal #>> '{}');
    END LOOP;
    -- Reutiliza la validación estricta de campos, límites, opciones y textos existentes.
    RETURN uony_requirements_conversation_form_valid(jsonb_set(form, '{context}',
        jsonb_build_object('kind','product_guide','sku',context->>'sku','revision',context->'revision',
                           'section','amazon_requirements','step','source')));
END;
$$;
ALTER TABLE uony_requests DROP CONSTRAINT uony_conversation_form_allowed;
ALTER TABLE uony_requests ADD CONSTRAINT uony_conversation_form_allowed
    CHECK (uony_conversation_form_valid(conversation_form)
        AND (conversation_form IS NULL OR conversation_form->>'id' = request_id::text));
