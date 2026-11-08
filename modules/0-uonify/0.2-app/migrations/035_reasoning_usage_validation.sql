-- Correct operator grouping when validating the reasoning usage ledger.
CREATE OR REPLACE FUNCTION uony_conversation_form_valid(form jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE reasoning jsonb; key text; clean jsonb;
BEGIN
    IF form IS NULL OR NOT form ? 'reasoning' THEN
        RETURN uony_pre_reasoning_form_valid(form);
    END IF;
    IF form->'context'->>'kind' IS DISTINCT FROM 'product_guide'
       OR form->'context'->>'section' IS DISTINCT FROM 'amazon_requirements' THEN RETURN false; END IF;
    reasoning := form->'reasoning';
    IF jsonb_typeof(reasoning) IS DISTINCT FROM 'object'
       OR NOT reasoning ?& ARRAY['id','status','message']
       OR reasoning - ARRAY['id','status','message','usage','canRetry',
          'requiresConsumptionAcknowledgement','requiresPreparation','materialsPending'] <> '{}'::jsonb
       OR reasoning->>'status' NOT IN ('queued','running','completed','error','unknown','stale')
       OR jsonb_typeof(reasoning->'status') IS DISTINCT FROM 'string'
       OR jsonb_typeof(reasoning->'message') IS DISTINCT FROM 'string'
       OR length(reasoning->>'message') NOT BETWEEN 1 AND 1000 THEN RETURN false; END IF;
    IF reasoning->'id' <> 'null'::jsonb AND (jsonb_typeof(reasoning->'id') IS DISTINCT FROM 'string'
       OR reasoning->>'id' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN RETURN false; END IF;
    FOREACH key IN ARRAY ARRAY['canRetry','requiresConsumptionAcknowledgement','requiresPreparation','materialsPending'] LOOP
        IF reasoning ? key AND jsonb_typeof(reasoning->key) IS DISTINCT FROM 'boolean' THEN RETURN false; END IF;
    END LOOP;
    IF reasoning ? 'usage' THEN
        IF jsonb_typeof(reasoning->'usage') IS DISTINCT FROM 'object'
           OR (reasoning->'usage') - ARRAY['calls','tokens','reserved','unknown'] <> '{}'::jsonb THEN RETURN false; END IF;
        FOR key IN SELECT jsonb_object_keys(reasoning->'usage') LOOP
            IF jsonb_typeof(reasoning->'usage'->key) IS DISTINCT FROM 'number'
               OR reasoning->'usage'->>key !~ '^[0-9]+$' THEN RETURN false; END IF;
        END LOOP;
    END IF;
    clean := form - 'reasoning';
    IF form->'context'->>'step' = 'reasoning' THEN
        IF form->'fields' IS DISTINCT FROM '[]'::jsonb THEN RETURN false; END IF;
        -- Reuse all established context/title/id constraints with a validation-only field.
        clean := jsonb_set(clean, '{context,step}', '"source"'::jsonb);
        clean := jsonb_set(clean, '{fields}', '[{"id":"waiting","label":"Revisión","type":"text","required":false}]'::jsonb);
    END IF;
    RETURN uony_pre_reasoning_form_valid(clean);
END;
$$;
