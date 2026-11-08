-- Instantáneas PTD por propietario, vendedor, producto y mercado. No contienen credenciales.
CREATE TABLE product_requirement_schemas (
    user_id uuid NOT NULL,
    product_id uuid NOT NULL,
    seller_id text NOT NULL,
    marketplace_id text NOT NULL,
    product_type text NOT NULL,
    reference_asin text,
    schema jsonb NOT NULL,
    metadata jsonb NOT NULL,
    fetched_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(user_id,product_id,seller_id,marketplace_id),
    FOREIGN KEY(user_id,product_id) REFERENCES products(user_id,id)
);
-- Preguntas dinámicas de la guía conservan el mismo request/hilo y revisión del producto.
ALTER FUNCTION uony_conversation_form_valid(jsonb) RENAME TO uony_incident_conversation_form_valid;
CREATE FUNCTION uony_conversation_form_valid(form jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE context jsonb; field jsonb; option jsonb; seen text[] := '{}';
BEGIN
    IF form IS NULL OR form->'context'->>'kind' IS DISTINCT FROM 'product_guide'
       OR form->'context'->>'section' IS DISTINCT FROM 'amazon_requirements' THEN
        RETURN uony_incident_conversation_form_valid(form);
    END IF;
    IF jsonb_typeof(form) <> 'object' OR NOT form ?& ARRAY['id','title','fields','context']
       OR form - ARRAY['id','title','fields','context','submitLabel','notice'] <> '{}'::jsonb
       OR form->>'id' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR length(form->>'title') NOT BETWEEN 1 AND 120 OR jsonb_typeof(form->'fields') <> 'array'
       OR jsonb_array_length(form->'fields') NOT BETWEEN 1 AND 8 THEN RETURN false; END IF;
    context := form->'context';
    IF jsonb_typeof(context) <> 'object'
       OR NOT context ?& ARRAY['kind','sku','revision','section','step']
       OR context - ARRAY['kind','sku','revision','section','step','evaluationId'] <> '{}'::jsonb
       OR context->>'sku' !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$'
       OR jsonb_typeof(context->'revision') <> 'number' OR context->>'revision' !~ '^[1-9][0-9]*$'
       OR context->>'step' NOT IN ('source','reference','type','fields')
       OR (context->>'step' = 'fields' AND (NOT context ? 'evaluationId' OR context->>'evaluationId' !~ '^[0-9a-f]{64}$'))
       THEN RETURN false; END IF;
    IF form ? 'notice' AND (jsonb_typeof(form->'notice') <> 'string' OR length(form->>'notice') > 1000) THEN RETURN false; END IF;
    IF form ? 'submitLabel' AND (jsonb_typeof(form->'submitLabel') <> 'string' OR length(form->>'submitLabel') > 100) THEN RETURN false; END IF;
    FOR field IN SELECT * FROM jsonb_array_elements(form->'fields') LOOP
        IF jsonb_typeof(field) <> 'object' OR NOT field ?& ARRAY['id','label','type','required']
           OR field - ARRAY['id','label','type','required','options','value','closed','validation','hint','suggestion'] <> '{}'::jsonb
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
        IF field ? 'suggestion' AND (jsonb_typeof(field->'suggestion') <> 'object'
           OR NOT field->'suggestion' ?& ARRAY['value','source']
           OR (field->'suggestion') - ARRAY['value','source'] <> '{}'::jsonb
           OR jsonb_typeof(field->'suggestion'->'value') <> 'string' OR length(field->'suggestion'->>'value') > 3000
           OR jsonb_typeof(field->'suggestion'->'source') <> 'string' OR length(field->'suggestion'->>'source') > 200) THEN RETURN false; END IF;
        IF field->>'type' = 'select' THEN
            IF jsonb_typeof(field->'options') <> 'array' OR jsonb_array_length(field->'options') NOT BETWEEN 1 AND 1000 THEN RETURN false; END IF;
            FOR option IN SELECT * FROM jsonb_array_elements(field->'options') LOOP
                IF jsonb_typeof(option) <> 'string' OR length(option #>> '{}') NOT BETWEEN 1 AND 160 THEN RETURN false; END IF;
            END LOOP;
            IF jsonb_array_length(field->'options') <> (SELECT count(DISTINCT item) FROM jsonb_array_elements(field->'options') item) THEN RETURN false; END IF;
        END IF;
    END LOOP;
    RETURN true;
END;
$$;
ALTER TABLE uony_requests DROP CONSTRAINT uony_conversation_form_allowed;
ALTER TABLE uony_requests ADD CONSTRAINT uony_conversation_form_allowed
    CHECK (uony_conversation_form_valid(conversation_form)
        AND (conversation_form IS NULL OR conversation_form->>'id' = request_id::text));
