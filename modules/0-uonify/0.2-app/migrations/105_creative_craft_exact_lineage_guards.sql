-- Exact candidate/native authority guards split from 103 for reviewability.

CREATE FUNCTION creative_native_project_revision_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE candidate_project uuid;
DECLARE candidate_engine text;
DECLARE candidate_operation text;
DECLARE target_mode text;
DECLARE admitted_sources jsonb;
DECLARE candidate_claim_set text;
DECLARE candidate_job uuid;
DECLARE candidate_graph text;
DECLARE candidate_recipe text;
DECLARE candidate_binding text;
DECLARE quarantine_step uuid;
DECLARE adoption_native jsonb;
BEGIN
    SELECT r.uonify_project_id,r.receipt->'engine'->>'name',
           r.receipt->'engine'->>'operation',
           t.craft_resolved_job_snapshot#>>'{target,editProject,mode}',
           (SELECT jsonb_agg(jsonb_build_object(
                'assetId',claim->>'assetId',
                'revision',(claim->>'assetRevision')::integer,
                'snapshotSha256',claim->>'snapshotSha256') ORDER BY ordinal)
              FROM jsonb_array_elements(d.input_claims)
                   WITH ORDINALITY source_claim(claim,ordinal)),
           r.claim_set_sha256,r.job_id,r.execution_graph_sha256,
           r.recipe_sha256,r.job_binding_sha256,q.adoption_step_id,
           adoption.result_receipt->'nativeProjectReceipt'
      INTO candidate_project,candidate_engine,candidate_operation,target_mode,
           admitted_sources,candidate_claim_set,candidate_job,candidate_graph,
           candidate_recipe,candidate_binding,quarantine_step,adoption_native
      FROM creative_candidate_receipts r
      JOIN creative_execution_attempts t
        ON t.user_id=r.user_id AND t.id=r.attempt_id
      JOIN creative_execution_admissions d
        ON d.user_id=r.user_id AND d.id=r.admission_id
      JOIN creative_candidate_quarantines q
        ON q.user_id=r.user_id AND q.candidate_id=r.id
      JOIN creative_execution_attempts adoption
        ON adoption.user_id=q.user_id AND adoption.id=q.adoption_attempt_id
     WHERE r.user_id=NEW.user_id AND r.id=NEW.candidate_id;
    IF candidate_engine NOT IN ('filmcraft','photocraft')
       OR candidate_engine IS DISTINCT FROM NEW.engine
       OR candidate_operation IS DISTINCT FROM NEW.operation
       OR candidate_project IS DISTINCT FROM (
            SELECT uonify_project_id FROM creative_native_projects
             WHERE user_id=NEW.user_id AND id=NEW.project_id)
       OR target_mode IS DISTINCT FROM 'create'
       OR NEW.mime_type IS DISTINCT FROM (CASE NEW.engine
            WHEN 'filmcraft' THEN 'application/json'
            WHEN 'photocraft' THEN 'application/zip' END)
       OR NEW.storage_name IS DISTINCT FROM
            'creative/users/' || NEW.user_id::text || '/native-projects/' ||
            NEW.project_id::text || '/' || NEW.sha256 || (CASE NEW.engine
                WHEN 'filmcraft' THEN '.fcproj' ELSE '.pcraft' END)
       OR NEW.input_claim_set_sha256 IS DISTINCT FROM candidate_claim_set
       OR NEW.source_job_id IS DISTINCT FROM candidate_job
       OR NEW.source_step_id IS DISTINCT FROM quarantine_step
       OR NEW.execution_graph_sha256 IS DISTINCT FROM candidate_graph
       OR (SELECT array_agg(key ORDER BY key)
             FROM jsonb_object_keys(NEW.lineage) AS keys(key)) IS DISTINCT FROM
          ARRAY['engine','jobBindingSha256','operation','origin',
                'recipeSha256','resultSha256','sources']::text[]
       OR NEW.lineage->>'origin' IS DISTINCT FROM 'craft'
       OR COALESCE(jsonb_array_length(NEW.lineage->'sources'),0) < 1
       OR NEW.lineage->'sources' IS DISTINCT FROM admitted_sources
       OR NEW.lineage->>'recipeSha256' IS DISTINCT FROM candidate_recipe
       OR NEW.lineage->>'jobBindingSha256' IS DISTINCT FROM candidate_binding
       OR NEW.lineage->>'engine' IS DISTINCT FROM NEW.engine
       OR NEW.lineage->>'operation' IS DISTINCT FROM NEW.operation
       OR NEW.lineage->>'resultSha256' IS DISTINCT FROM NEW.sha256
       OR adoption_native IS DISTINCT FROM jsonb_build_object(
            'projectId',NEW.project_id::text,'revision',NEW.revision,
            'receipt',jsonb_build_object(
                'bucket',NEW.storage_bucket,'name',NEW.storage_name,
                'generation',NEW.storage_generation,'mimeType',NEW.mime_type,
                'byteSize',NEW.byte_size,'sha256',NEW.sha256)) THEN
        RAISE EXCEPTION 'creative native project authority is not exact';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER creative_native_project_revision_guard
    BEFORE INSERT ON creative_native_project_revisions
    FOR EACH ROW EXECUTE FUNCTION creative_native_project_revision_guard();

CREATE FUNCTION creative_candidate_asset_lineage_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE engine_name text;
DECLARE declared_sources jsonb;
DECLARE persisted_sources jsonb;
DECLARE admitted_sources jsonb;
DECLARE candidate_operation text;
DECLARE candidate_recipe text;
DECLARE candidate_binding text;
DECLARE candidate_job uuid;
DECLARE candidate_graph text;
DECLARE candidate_project uuid;
DECLARE output_project uuid;
DECLARE adoption_step uuid;
DECLARE output_job uuid;
DECLARE output_step uuid;
DECLARE output_graph text;
DECLARE output_sha text;
DECLARE output_lineage jsonb;
BEGIN
    SELECT r.receipt->'engine'->>'name',v.lineage->'sources',
           (SELECT jsonb_agg(jsonb_build_object(
                'assetId',claim->>'assetId',
                'revision',(claim->>'assetRevision')::integer,
                'snapshotSha256',claim->>'snapshotSha256') ORDER BY ordinal)
              FROM jsonb_array_elements(d.input_claims)
                   WITH ORDINALITY source_claim(claim,ordinal)),
           (SELECT jsonb_agg(jsonb_build_object(
                'assetId',edge.source_asset_id::text,
                'revision',edge.source_revision,
                'snapshotSha256',edge.source_snapshot_sha256)
                ORDER BY edge.ordinal)
              FROM creative_asset_lineage_sources edge
             WHERE edge.user_id=NEW.user_id
               AND edge.output_asset_id=NEW.asset_id
               AND edge.output_revision=NEW.revision),
           r.receipt->'engine'->>'operation',r.recipe_sha256,
           r.job_binding_sha256,r.job_id,r.execution_graph_sha256,
           r.uonify_project_id,a.uonify_project_id,q.adoption_step_id,
           v.source_job_id,v.source_step_id,v.execution_graph_sha256,v.sha256,
           v.lineage
      INTO engine_name,declared_sources,admitted_sources,persisted_sources,
           candidate_operation,candidate_recipe,candidate_binding,
           candidate_job,candidate_graph,candidate_project,output_project,
           adoption_step,output_job,output_step,output_graph,output_sha,
           output_lineage
      FROM creative_candidate_receipts r
      JOIN creative_execution_admissions d
        ON d.user_id=r.user_id AND d.id=r.admission_id
      JOIN creative_asset_revisions v
        ON v.user_id=NEW.user_id AND v.asset_id=NEW.asset_id
       AND v.revision=NEW.revision
      JOIN creative_assets a
        ON a.user_id=v.user_id AND a.id=v.asset_id
      JOIN creative_candidate_quarantines q
        ON q.user_id=r.user_id AND q.candidate_id=r.id
     WHERE r.user_id=NEW.user_id AND r.id=NEW.candidate_id;
    IF engine_name IN ('filmcraft','photocraft') AND (
       COALESCE(jsonb_array_length(declared_sources),0) < 1
       OR declared_sources IS DISTINCT FROM admitted_sources
       OR persisted_sources IS DISTINCT FROM admitted_sources
       OR candidate_project IS DISTINCT FROM output_project
       OR output_job IS DISTINCT FROM candidate_job
       OR output_step IS DISTINCT FROM adoption_step
       OR output_graph IS DISTINCT FROM candidate_graph
       OR (SELECT array_agg(key ORDER BY key)
             FROM jsonb_object_keys(output_lineage) AS keys(key)) IS DISTINCT FROM
          ARRAY['engine','jobBindingSha256','operation','origin',
                'recipeSha256','resultSha256','sources']::text[]
       OR output_lineage->>'origin' IS DISTINCT FROM 'craft'
       OR output_lineage->>'engine' IS DISTINCT FROM engine_name
       OR output_lineage->>'operation' IS DISTINCT FROM candidate_operation
       OR output_lineage->>'recipeSha256' IS DISTINCT FROM candidate_recipe
       OR output_lineage->>'jobBindingSha256' IS DISTINCT FROM candidate_binding
       OR output_lineage->>'resultSha256' IS DISTINCT FROM output_sha) THEN
        RAISE EXCEPTION 'creative candidate asset lineage is not exact';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER creative_candidate_asset_lineage_guard
    BEFORE INSERT ON creative_candidate_quarantine_assets
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_asset_lineage_guard();
