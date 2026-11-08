-- Narrow creative authority to the tables and columns each isolated service uses.
DO $$ DECLARE schema_name text := current_schema(); BEGIN
    EXECUTE format('REVOKE SELECT,UPDATE ON ALL TABLES IN SCHEMA %I FROM
        uonify_creative_inspector,uonify_creative_evaluator,
        uonify_creative_reviewer,uonify_app_runtime',schema_name);
END $$;

GRANT SELECT ON users,creative_candidate_receipts,creative_candidate_states,
    creative_candidate_quarantine_assets,creative_asset_revisions,
    creative_inspection_implementations,creative_candidate_inspections
    TO uonify_creative_inspector;
GRANT INSERT ON creative_inspection_implementations,
    creative_candidate_inspections TO uonify_creative_inspector;

GRANT SELECT ON users,creative_candidate_receipts,creative_candidate_states,
    creative_candidate_quarantine_assets,creative_asset_revisions,
    creative_inspection_implementations,creative_candidate_inspections,
    creative_evaluation_policies,creative_candidate_evaluations
    TO uonify_creative_evaluator;
GRANT INSERT ON creative_evaluation_policies,creative_candidate_evaluations
    TO uonify_creative_evaluator;
GRANT UPDATE (state,version,updated_at) ON creative_candidate_states
    TO uonify_creative_evaluator;

GRANT SELECT ON users,creative_candidate_receipts,creative_candidate_states,
    creative_candidate_quarantine_assets,creative_asset_revisions,
    creative_inspection_implementations,creative_candidate_inspections,
    creative_evaluation_policies,creative_candidate_evaluations,
    creative_candidate_reviews,creative_candidate_releases,uony_projects,
    creative_assets,creative_execution_admissions,creative_execution_jobs,
    creative_execution_approvals,creative_execution_quotes,
    creative_execution_steps,uony_creative_plans,uony_threads,
    google_cloud_connections TO uonify_creative_reviewer;
GRANT INSERT ON creative_candidate_reviews,creative_candidate_releases
    TO uonify_creative_reviewer;
GRANT UPDATE (state,version,accepted_for_use,updated_at)
    ON creative_candidate_states TO uonify_creative_reviewer;
GRANT UPDATE (authorization_state,state_reason,updated_at)
    ON creative_assets TO uonify_creative_reviewer;

CREATE OR REPLACE FUNCTION creative_candidate_state_role_guard() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
    IF current_user='uonify_creative_inspector' THEN
        RAISE EXCEPTION 'creative inspector cannot update candidate state'
            USING ERRCODE='42501';
    ELSIF current_user='uonify_creative_evaluator' THEN
        IF NOT (OLD.state='quarantined'
                AND NEW.state IN ('review_pending','blocked')) THEN
            RAISE EXCEPTION 'creative evaluator transition denied'
                USING ERRCODE='42501';
        END IF;
    ELSIF current_user='uonify_creative_reviewer' THEN
        IF NOT ((OLD.state='review_pending' AND NEW.state IN
                    ('approved_for_use','revision_requested','rejected'))
                OR (OLD.state='approved_for_use' AND NEW.state='released')) THEN
            RAISE EXCEPTION 'creative reviewer transition denied'
                USING ERRCODE='42501';
        END IF;
    ELSIF (OLD.state='quarantined'
            AND NEW.state IN ('review_pending','blocked')) THEN
        RAISE EXCEPTION 'creative evaluator role required' USING ERRCODE='42501';
    ELSIF (OLD.state='review_pending'
            OR (OLD.state='approved_for_use' AND NEW.state='released')) THEN
        RAISE EXCEPTION 'creative reviewer role required' USING ERRCODE='42501';
    END IF;
    RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION creative_asset_release_role_guard() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
    IF current_user IN ('uonify_creative_inspector',
                        'uonify_creative_evaluator') THEN
        RAISE EXCEPTION 'creative authority cannot update asset'
            USING ERRCODE='42501';
    ELSIF current_user='uonify_creative_reviewer' THEN
        IF NOT (OLD.authorization_state='quarantined'
                AND NEW.authorization_state='allowed'
                AND OLD.user_id=NEW.user_id AND OLD.id=NEW.id
                AND OLD.uonify_project_id IS NOT DISTINCT FROM NEW.uonify_project_id
                AND OLD.current_revision=NEW.current_revision
                AND OLD.created_at=NEW.created_at
                AND OLD.revoked_at IS NOT DISTINCT FROM NEW.revoked_at) THEN
            RAISE EXCEPTION 'creative reviewer asset transition denied'
                USING ERRCODE='42501';
        END IF;
    ELSIF OLD.authorization_state='quarantined'
       AND NEW.authorization_state='allowed' THEN
        RAISE EXCEPTION 'creative reviewer role required' USING ERRCODE='42501';
    END IF;
    RETURN NEW;
END; $$;

CREATE FUNCTION creative_inspection_state_lock_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE candidate_state text;
DECLARE set_sha text;
DECLARE deleting timestamptz;
BEGIN
    EXECUTE format('SELECT deletion_requested_at FROM %I.users
        WHERE id=$1 FOR SHARE',TG_TABLE_SCHEMA)
        INTO deleting USING NEW.user_id;
    IF deleting IS NOT NULL THEN
        RAISE EXCEPTION 'creative authority owner is deleting'
            USING ERRCODE='55000';
    END IF;
    EXECUTE format('SELECT state,quarantine_set_sha256 FROM %I.creative_candidate_states
        WHERE user_id=$1 AND candidate_id=$2 FOR SHARE',TG_TABLE_SCHEMA)
        INTO candidate_state,set_sha USING NEW.user_id,NEW.candidate_id;
    IF candidate_state IS DISTINCT FROM 'quarantined'
       OR set_sha IS DISTINCT FROM NEW.quarantine_set_sha256 THEN
        RAISE EXCEPTION 'creative inspection candidate changed'
            USING ERRCODE='40001';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER creative_inspection_state_lock_guard
    BEFORE INSERT ON creative_candidate_inspections
    FOR EACH ROW EXECUTE FUNCTION creative_inspection_state_lock_guard();

DO $$ DECLARE schema_name text := current_schema(); BEGIN
    EXECUTE format($ddl$
        CREATE FUNCTION %I.creative_lock_candidate_owner_authority(
            owner_id uuid,candidate_key uuid,required_role text) RETURNS void
        LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $body$
        DECLARE schema_name constant text := %L;
        DECLARE found_candidate boolean;
        DECLARE deleting timestamptz;
        BEGIN
            IF required_role NOT IN ('uonify_creative_evaluator',
                                     'uonify_creative_reviewer')
               OR current_setting('role',true) IS DISTINCT FROM required_role THEN
                RAISE EXCEPTION 'creative authority role required'
                    USING ERRCODE='42501';
            END IF;
            EXECUTE format('SELECT deletion_requested_at FROM %%I.users
                WHERE id=$1 FOR SHARE',schema_name)
                INTO deleting USING owner_id;
            IF deleting IS NOT NULL THEN
                RAISE EXCEPTION 'creative authority owner is deleting'
                    USING ERRCODE='55000';
            END IF;
            EXECUTE format('SELECT EXISTS(SELECT 1 FROM %%I.creative_candidate_receipts
                WHERE user_id=$1 AND id=$2)',schema_name)
                INTO found_candidate USING owner_id,candidate_key;
            IF NOT found_candidate THEN
                RAISE EXCEPTION 'creative candidate authority missing';
            END IF;
        END; $body$;
    $ddl$,schema_name,schema_name);
    EXECUTE format($ddl$
        CREATE FUNCTION %I.creative_lock_candidate_release_authority(
            owner_id uuid,candidate_key uuid) RETURNS void
        LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $body$
        DECLARE schema_name constant text := %L;
        DECLARE job_key uuid;
        DECLARE project_key uuid;
        DECLARE approval_key uuid;
        DECLARE quote_key uuid;
        DECLARE plan_key uuid;
        DECLARE thread_key text;
        DECLARE deleting timestamptz;
        BEGIN
            IF current_setting('role',true)
               IS DISTINCT FROM 'uonify_creative_reviewer' THEN
                RAISE EXCEPTION 'creative reviewer role required'
                    USING ERRCODE='42501';
            END IF;
            EXECUTE format('SELECT deletion_requested_at FROM %%I.users
                WHERE id=$1 FOR SHARE',schema_name)
                INTO deleting USING owner_id;
            IF deleting IS NOT NULL THEN
                RAISE EXCEPTION 'creative authority owner is deleting'
                    USING ERRCODE='55000';
            END IF;
            EXECUTE format('SELECT job_id,uonify_project_id FROM %%I.creative_candidate_receipts
                WHERE user_id=$1 AND id=$2',schema_name)
                INTO job_key,project_key USING owner_id,candidate_key;
            IF job_key IS NULL THEN
                RAISE EXCEPTION 'creative candidate authority missing';
            END IF;
            IF project_key IS NOT NULL THEN
                EXECUTE format('SELECT 1 FROM %%I.uony_projects
                    WHERE user_id=$1 AND id=$2 FOR SHARE',schema_name)
                    USING owner_id,project_key;
            END IF;
            EXECUTE format('SELECT approval_id,thread_id FROM %%I.creative_execution_jobs
                WHERE user_id=$1 AND id=$2 FOR SHARE',schema_name)
                INTO approval_key,thread_key USING owner_id,job_key;
            PERFORM pg_advisory_xact_lock(
                hashtextextended(owner_id::text || ':' || thread_key,0));
            EXECUTE format('SELECT 1 FROM %%I.creative_execution_admissions
                WHERE user_id=$1 AND job_id=$2 FOR SHARE',schema_name)
                USING owner_id,job_key;
            EXECUTE format('SELECT quote_id FROM %%I.creative_execution_approvals
                WHERE user_id=$1 AND id=$2 FOR SHARE',schema_name)
                INTO quote_key USING owner_id,approval_key;
            EXECUTE format('SELECT plan_id FROM %%I.creative_execution_quotes
                WHERE user_id=$1 AND id=$2 FOR SHARE',schema_name)
                INTO plan_key USING owner_id,quote_key;
            EXECUTE format('SELECT 1 FROM %%I.creative_execution_steps
                WHERE user_id=$1 AND job_id=$2 FOR SHARE',schema_name)
                USING owner_id,job_key;
            EXECUTE format('SELECT 1 FROM %%I.uony_creative_plans
                WHERE user_id=$1 AND id=$2 FOR SHARE',schema_name)
                USING owner_id,plan_key;
            EXECUTE format('SELECT 1 FROM %%I.uony_threads
                WHERE user_id=$1 AND id=$2 FOR SHARE',schema_name)
                USING owner_id,thread_key;
            EXECUTE format('SELECT 1 FROM %%I.google_cloud_connections
                WHERE user_id=$1 FOR SHARE',schema_name) USING owner_id;
            EXECUTE format('SELECT 1 FROM %%I.creative_assets a
                JOIN %%I.creative_execution_admissions d
                  ON d.user_id=a.user_id AND d.job_id=$2
                JOIN LATERAL jsonb_array_elements(d.input_claims) claim
                  ON claim->>''assetId''=a.id::text
                WHERE a.user_id=$1 FOR SHARE OF a',schema_name,schema_name)
                USING owner_id,job_key;
            EXECUTE format('SELECT 1 FROM %%I.creative_asset_revisions r
                JOIN %%I.creative_execution_admissions d
                  ON d.user_id=r.user_id AND d.job_id=$2
                JOIN LATERAL jsonb_array_elements(d.input_claims) claim
                  ON claim->>''assetId''=r.asset_id::text
                 AND (claim->>''assetRevision'')::integer=r.revision
                WHERE r.user_id=$1 FOR SHARE OF r',schema_name,schema_name)
                USING owner_id,job_key;
        END; $body$;
    $ddl$,schema_name,schema_name);
END $$;
REVOKE ALL ON FUNCTION creative_lock_candidate_owner_authority(uuid,uuid,text)
    FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector;
GRANT EXECUTE ON FUNCTION creative_lock_candidate_owner_authority(uuid,uuid,text)
    TO uonify_creative_evaluator,uonify_creative_reviewer;
REVOKE ALL ON FUNCTION creative_lock_candidate_release_authority(uuid,uuid)
    FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,
         uonify_creative_evaluator;
GRANT EXECUTE ON FUNCTION creative_lock_candidate_release_authority(uuid,uuid)
    TO uonify_creative_reviewer;
