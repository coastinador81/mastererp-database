-- A conversation can now retain the exact pre-product job it started. Keep
-- the earlier product/SKU card shape and reject arbitrary model-supplied data.
ALTER TABLE uony_requests DROP CONSTRAINT uony_material_analysis_valid;
ALTER TABLE uony_requests ADD CONSTRAINT uony_material_analysis_valid CHECK (
    material_analysis IS NULL OR (
        jsonb_typeof(material_analysis)='object' AND (
            (material_analysis ?& ARRAY['sku','revision']
                AND material_analysis - ARRAY['sku','revision']='{}'::jsonb
                AND jsonb_typeof(material_analysis->'sku')='string'
                AND material_analysis->>'sku' ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$'
                AND jsonb_typeof(material_analysis->'revision')='number'
                AND material_analysis->>'revision' ~ '^[1-9][0-9]*$')
            OR (material_analysis ?& ARRAY['jobId','intakeId']
                AND material_analysis - ARRAY['jobId','intakeId','assignmentId']='{}'::jsonb
                AND jsonb_typeof(material_analysis->'jobId')='string'
                AND material_analysis->>'jobId' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                AND (jsonb_typeof(material_analysis->'intakeId')='null'
                     OR (jsonb_typeof(material_analysis->'intakeId')='string'
                         AND material_analysis->>'intakeId' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
                AND (NOT material_analysis ? 'assignmentId'
                     OR (jsonb_typeof(material_analysis->'assignmentId')='string'
                         AND material_analysis->>'assignmentId' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')))
        )
    )
);
