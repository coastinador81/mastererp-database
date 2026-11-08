-- Only the server-issued, informational product-source choice may render inline.
-- Existing forms remain valid and keep their stored shape. The wrapper can be
-- rolled back after removing the marker from newly stored rows.
ALTER FUNCTION uony_conversation_form_valid(jsonb) RENAME TO uony_pre_inline_choice_form_valid;
CREATE FUNCTION uony_conversation_form_valid(form jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF form IS NULL OR NOT form ? 'presentation' THEN
        RETURN uony_pre_inline_choice_form_valid(form);
    END IF;
    IF jsonb_typeof(form->'presentation') IS DISTINCT FROM 'string'
       OR form->>'presentation' IS DISTINCT FROM 'inline_choice'
       OR form ? 'context' OR jsonb_typeof(form->'fields') IS DISTINCT FROM 'array'
       THEN RETURN false; END IF;
    IF jsonb_array_length(form->'fields') <> 1
       OR form->'fields'->0 IS DISTINCT FROM
          '{"id":"product_sources","label":"¿Tienes fotos o documentos del producto, o partimos desde cero?","type":"select","required":true,"options":["Tengo una carpeta en Drive","Partimos desde cero"]}'::jsonb
       THEN RETURN false; END IF;
    RETURN uony_pre_inline_choice_form_valid(form - 'presentation');
END;
$$;
ALTER TABLE uony_requests DROP CONSTRAINT uony_conversation_form_allowed;
ALTER TABLE uony_requests ADD CONSTRAINT uony_conversation_form_allowed
    CHECK (uony_conversation_form_valid(conversation_form)
        AND (conversation_form IS NULL OR conversation_form->>'id' = request_id::text));
