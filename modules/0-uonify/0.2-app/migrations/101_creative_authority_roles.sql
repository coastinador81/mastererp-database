-- Separate inactive creative services from the ordinary application runtime.
-- These NOLOGIN roles are assumed only by dedicated worker credentials; the
-- current web runtime receives no creative-authority write grant.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles
                   WHERE rolname='uonify_creative_inspector') THEN
        CREATE ROLE uonify_creative_inspector NOLOGIN NOINHERIT
            NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles
                   WHERE rolname='uonify_creative_evaluator') THEN
        CREATE ROLE uonify_creative_evaluator NOLOGIN NOINHERIT
            NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles
                   WHERE rolname='uonify_creative_reviewer') THEN
        CREATE ROLE uonify_creative_reviewer NOLOGIN NOINHERIT
            NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles
                   WHERE rolname='uonify_app_runtime') THEN
        CREATE ROLE uonify_app_runtime NOLOGIN NOINHERIT
            NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
    END IF;
END $$;

DO $$ DECLARE schema_name text := current_schema(); BEGIN
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO uonify_creative_inspector,
        uonify_creative_evaluator,uonify_creative_reviewer,uonify_app_runtime',
        schema_name);
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

CREATE FUNCTION creative_authority_role_guard() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
    IF current_user IS DISTINCT FROM TG_ARGV[0] THEN
        RAISE EXCEPTION 'creative authority role required: %',TG_ARGV[0]
            USING ERRCODE='42501';
    END IF;
    RETURN NEW;
END; $$;

CREATE TRIGGER creative_inspection_implementation_role
    BEFORE INSERT ON creative_inspection_implementations
    FOR EACH ROW EXECUTE FUNCTION creative_authority_role_guard(
        'uonify_creative_inspector');
CREATE TRIGGER creative_inspection_role
    BEFORE INSERT ON creative_candidate_inspections
    FOR EACH ROW EXECUTE FUNCTION creative_authority_role_guard(
        'uonify_creative_inspector');
CREATE TRIGGER creative_evaluation_policy_role
    BEFORE INSERT ON creative_evaluation_policies
    FOR EACH ROW EXECUTE FUNCTION creative_authority_role_guard(
        'uonify_creative_evaluator');
CREATE TRIGGER creative_evaluation_role
    BEFORE INSERT ON creative_candidate_evaluations
    FOR EACH ROW EXECUTE FUNCTION creative_authority_role_guard(
        'uonify_creative_evaluator');
CREATE TRIGGER creative_review_role
    BEFORE INSERT ON creative_candidate_reviews
    FOR EACH ROW EXECUTE FUNCTION creative_authority_role_guard(
        'uonify_creative_reviewer');
CREATE TRIGGER creative_release_role
    BEFORE INSERT ON creative_candidate_releases
    FOR EACH ROW EXECUTE FUNCTION creative_authority_role_guard(
        'uonify_creative_reviewer');

CREATE FUNCTION creative_candidate_state_role_guard() RETURNS trigger
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
CREATE TRIGGER creative_candidate_state_role_guard
    BEFORE UPDATE ON creative_candidate_states
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_state_role_guard();

CREATE FUNCTION creative_asset_release_role_guard() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
    IF current_user IN ('uonify_creative_inspector',
                        'uonify_creative_evaluator') THEN
        RAISE EXCEPTION 'creative authority cannot update asset'
            USING ERRCODE='42501';
    ELSIF current_user='uonify_creative_reviewer'
       AND NOT (OLD.authorization_state='quarantined'
                AND NEW.authorization_state='allowed'
                AND OLD.user_id=NEW.user_id AND OLD.id=NEW.id
                AND OLD.uonify_project_id IS NOT DISTINCT FROM NEW.uonify_project_id
                AND OLD.current_revision=NEW.current_revision
                AND OLD.created_at=NEW.created_at
                AND OLD.revoked_at IS NOT DISTINCT FROM NEW.revoked_at) THEN
        RAISE EXCEPTION 'creative reviewer asset transition denied'
            USING ERRCODE='42501';
    ELSIF OLD.authorization_state='quarantined'
       AND NEW.authorization_state='allowed' THEN
        RAISE EXCEPTION 'creative reviewer role required' USING ERRCODE='42501';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER creative_asset_release_role_guard
    BEFORE UPDATE ON creative_assets
    FOR EACH ROW EXECUTE FUNCTION creative_asset_release_role_guard();

REVOKE ALL ON creative_inspection_implementations,
    creative_candidate_inspections,creative_evaluation_policies,
    creative_candidate_evaluations,creative_candidate_reviews,
    creative_candidate_releases FROM PUBLIC,uonify_app_runtime;
