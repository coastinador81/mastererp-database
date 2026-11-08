-- La guía añade contexto emitido por servidor; los formularios libres conservan el esquema 020.
ALTER TABLE uony_requests ADD COLUMN form_response jsonb;
ALTER TABLE uony_requests DROP CONSTRAINT uony_conversation_form_allowed;
ALTER FUNCTION uony_conversation_form_valid(jsonb) RENAME TO uony_base_conversation_form_valid;
CREATE FUNCTION uony_conversation_form_valid(form jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE context jsonb;
BEGIN
    IF form IS NULL THEN RETURN true; END IF;
    IF NOT uony_base_conversation_form_valid(form - 'context') THEN RETURN false; END IF;
    IF NOT form ? 'context' THEN RETURN true; END IF;
    context := form->'context';
    IF jsonb_typeof(context) <> 'object' OR NOT context ?& ARRAY['kind','sku','revision','section']
        OR context - ARRAY['kind','sku','revision','section'] <> '{}'::jsonb THEN RETURN false; END IF;
    IF context->>'kind' IS DISTINCT FROM 'product_guide' OR jsonb_typeof(context->'sku') <> 'string'
        OR context->>'sku' !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$'
        OR jsonb_typeof(context->'revision') <> 'number' OR context->>'revision' !~ '^[1-9][0-9]*$'
        OR jsonb_typeof(context->'section') <> 'string'
        OR context->>'section' NOT IN ('choice','atributos','auditoria','descripciones','gpsr','imagenes','modelos3d','video','aplus')
        THEN RETURN false; END IF;
    RETURN true;
END;
$$;
ALTER TABLE uony_requests ADD CONSTRAINT uony_conversation_form_allowed
    CHECK (uony_conversation_form_valid(conversation_form)
        AND (conversation_form IS NULL OR conversation_form->>'id' = request_id::text));
