-- Cada pregunta revisa todas las alternativas del atributo, con versión de evidencia.
ALTER FUNCTION uony_conversation_form_valid(jsonb) RENAME TO uony_material_legacy_form_valid;
CREATE FUNCTION uony_conversation_form_valid(form jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE context jsonb; members jsonb; member jsonb; seen text[] := '{}'; position integer := 0;
BEGIN
    IF form IS NULL OR form->'context'->>'kind' IS DISTINCT FROM 'drive_analysis' THEN
        RETURN uony_material_legacy_form_valid(form);
    END IF;
    context := form->'context';
    IF NOT context ? 'proposalGroups' AND NOT context ? 'proposalFingerprint' THEN
        RETURN uony_material_legacy_form_valid(form);
    END IF;
    IF NOT context ?& ARRAY['proposalGroups','proposalFingerprint']
       OR jsonb_typeof(context->'proposalFingerprint') <> 'string'
       OR context->>'proposalFingerprint' !~ '^[0-9a-f]{64}$'
       OR jsonb_typeof(context->'proposalGroups') <> 'array'
       OR jsonb_array_length(context->'proposalGroups') NOT BETWEEN 1 AND 7
       OR jsonb_array_length(context->'proposalGroups') <> jsonb_array_length(context->'proposalIds')
       THEN RETURN false; END IF;
    FOR members IN SELECT * FROM jsonb_array_elements(context->'proposalGroups') LOOP
        IF jsonb_typeof(members) <> 'array' OR jsonb_array_length(members) < 1
           OR members->0 IS DISTINCT FROM context->'proposalIds'->position THEN RETURN false; END IF;
        FOR member IN SELECT * FROM jsonb_array_elements(members) LOOP
            IF jsonb_typeof(member) <> 'string' OR length(member #>> '{}') NOT BETWEEN 1 AND 100
               OR member #>> '{}' = ANY(seen) THEN RETURN false; END IF;
            seen := array_append(seen, member #>> '{}');
        END LOOP;
        position := position + 1;
    END LOOP;
    RETURN uony_material_legacy_form_valid(jsonb_set(form, '{context}',
        context - ARRAY['proposalGroups','proposalFingerprint']));
END;
$$;
ALTER TABLE uony_requests DROP CONSTRAINT uony_conversation_form_allowed;
ALTER TABLE uony_requests ADD CONSTRAINT uony_conversation_form_allowed
    CHECK (uony_conversation_form_valid(conversation_form)
        AND (conversation_form IS NULL OR conversation_form->>'id' = request_id::text));
