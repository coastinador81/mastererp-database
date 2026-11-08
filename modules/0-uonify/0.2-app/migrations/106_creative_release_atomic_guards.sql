-- Require durable approved release authority before promoting creative assets.

CREATE OR REPLACE FUNCTION creative_asset_release_role_guard() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
    IF current_user IN ('uonify_creative_inspector','uonify_creative_evaluator') THEN
        RAISE EXCEPTION 'creative authority cannot update asset'
            USING ERRCODE='42501';
    ELSIF OLD.authorization_state='quarantined'
       AND NEW.authorization_state='allowed' THEN
        IF current_user<>'uonify_creative_reviewer' OR NOT EXISTS (
            SELECT 1 FROM creative_candidate_quarantine_assets q
            JOIN creative_candidate_releases rel
              ON rel.user_id=q.user_id AND rel.candidate_id=q.candidate_id
            JOIN creative_candidate_reviews review
              ON review.user_id=rel.user_id AND review.id=rel.review_id
            JOIN creative_candidate_states state
              ON state.user_id=q.user_id AND state.candidate_id=q.candidate_id
           WHERE q.user_id=NEW.user_id AND q.asset_id=NEW.id
             AND q.revision=NEW.current_revision
             AND review.decision='approved_for_use'
             AND state.state='approved_for_use'
             AND rel.receipt->'assets' @> jsonb_build_array(jsonb_build_object(
                'assetId',NEW.id::text,'revision',NEW.current_revision,
                'snapshotSha256',q.snapshot_sha256))) THEN
            RAISE EXCEPTION 'creative asset release authority missing'
                USING ERRCODE='42501';
        END IF;
        IF (OLD.user_id,OLD.id,OLD.uonify_project_id,OLD.current_revision,
            OLD.created_at,OLD.revoked_at) IS DISTINCT FROM
           (NEW.user_id,NEW.id,NEW.uonify_project_id,NEW.current_revision,
            NEW.created_at,NEW.revoked_at) THEN
            RAISE EXCEPTION 'creative reviewer asset transition denied'
                USING ERRCODE='42501';
        END IF;
    END IF;
    RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION creative_native_project_identity_guard()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
    IF (OLD.user_id,OLD.id,OLD.uonify_project_id,OLD.current_revision,
        OLD.created_at) IS DISTINCT FROM
       (NEW.user_id,NEW.id,NEW.uonify_project_id,NEW.current_revision,
        NEW.created_at) THEN
        RAISE EXCEPTION 'creative native project identity is immutable';
    END IF;
    IF OLD.authorization_state='quarantined'
       AND NEW.authorization_state='allowed' THEN
        IF current_user<>'uonify_creative_reviewer' OR NOT EXISTS (
            SELECT 1 FROM creative_candidate_native_projects link
            JOIN creative_candidate_releases rel
              ON rel.user_id=link.user_id AND rel.candidate_id=link.candidate_id
            JOIN creative_candidate_reviews review
              ON review.user_id=rel.user_id AND review.id=rel.review_id
            JOIN creative_candidate_states state
              ON state.user_id=link.user_id
             AND state.candidate_id=link.candidate_id
           WHERE link.user_id=NEW.user_id AND link.project_id=NEW.id
             AND link.revision=NEW.current_revision
             AND review.decision='approved_for_use'
             AND state.state='approved_for_use'
             AND rel.receipt->'nativeProjects' @> jsonb_build_array(
                jsonb_build_object('projectId',NEW.id::text,
                    'revision',NEW.current_revision,
                    'snapshotSha256',link.snapshot_sha256))) THEN
            RAISE EXCEPTION 'creative native release authority missing'
                USING ERRCODE='42501';
        END IF;
    ELSIF current_user='uonify_creative_reviewer'
       AND OLD IS DISTINCT FROM NEW THEN
        RAISE EXCEPTION 'creative reviewer native project transition denied'
            USING ERRCODE='42501';
    END IF;
    RETURN NEW;
END; $$;

CREATE FUNCTION creative_release_commit_guard() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
    IF OLD.authorization_state='quarantined'
       AND NEW.authorization_state='allowed' AND NOT EXISTS (
        SELECT 1 FROM creative_candidate_states state
        JOIN creative_candidate_releases rel
          ON rel.user_id=state.user_id AND rel.candidate_id=state.candidate_id
        LEFT JOIN creative_candidate_quarantine_assets asset
          ON TG_TABLE_NAME='creative_assets' AND asset.user_id=state.user_id
         AND asset.candidate_id=state.candidate_id AND asset.asset_id=NEW.id
        LEFT JOIN creative_candidate_native_projects native
          ON TG_TABLE_NAME='creative_native_projects'
         AND native.user_id=state.user_id
         AND native.candidate_id=state.candidate_id
         AND native.project_id=NEW.id
       WHERE state.user_id=NEW.user_id AND state.state='released'
         AND (asset.asset_id IS NOT NULL OR native.project_id IS NOT NULL)) THEN
        RAISE EXCEPTION 'creative release transaction is incomplete'
            USING ERRCODE='40001';
    END IF;
    RETURN NEW;
END; $$;
CREATE CONSTRAINT TRIGGER creative_asset_release_commit_guard
    AFTER UPDATE ON creative_assets DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION creative_release_commit_guard();
CREATE CONSTRAINT TRIGGER creative_native_release_commit_guard
    AFTER UPDATE ON creative_native_projects DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION creative_release_commit_guard();

CREATE FUNCTION creative_candidate_release_complete_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE release_receipt jsonb;
DECLARE expected_assets jsonb;
DECLARE expected_native jsonb;
DECLARE engine_name text;
DECLARE missing_assets integer;
DECLARE native_count integer;
DECLARE missing_native integer;
BEGIN
    IF OLD.state<>'approved_for_use' OR NEW.state<>'released' THEN
        RETURN NEW;
    END IF;
    SELECT rel.receipt,r.receipt->'engine'->>'name',
           (SELECT jsonb_agg(jsonb_build_object(
                'assetId',q.asset_id::text,'revision',q.revision,
                'snapshotSha256',q.snapshot_sha256) ORDER BY q.ordinal)
              FROM creative_candidate_quarantine_assets q
             WHERE q.user_id=NEW.user_id AND q.candidate_id=NEW.candidate_id),
           (SELECT count(*) FROM creative_candidate_quarantine_assets q
              JOIN creative_assets a ON a.user_id=q.user_id AND a.id=q.asset_id
             WHERE q.user_id=NEW.user_id AND q.candidate_id=NEW.candidate_id
               AND (a.authorization_state<>'allowed'
                    OR a.current_revision<>q.revision)),
           (SELECT jsonb_agg(jsonb_build_object(
                'projectId',link.project_id::text,'revision',link.revision,
                'snapshotSha256',link.snapshot_sha256) ORDER BY link.project_id)
              FROM creative_candidate_native_projects link
             WHERE link.user_id=NEW.user_id
               AND link.candidate_id=NEW.candidate_id),
           (SELECT count(*) FROM creative_candidate_native_projects link
              WHERE link.user_id=NEW.user_id
                AND link.candidate_id=NEW.candidate_id),
           (SELECT count(*) FROM creative_candidate_native_projects link
              JOIN creative_native_projects project
                ON project.user_id=link.user_id AND project.id=link.project_id
             WHERE link.user_id=NEW.user_id
               AND link.candidate_id=NEW.candidate_id
               AND (project.authorization_state<>'allowed'
                    OR project.current_revision<>link.revision))
      INTO release_receipt,engine_name,expected_assets,missing_assets,
           expected_native,native_count,missing_native
      FROM creative_candidate_receipts r
      JOIN creative_candidate_releases rel
        ON rel.user_id=r.user_id AND rel.candidate_id=r.id
     WHERE r.user_id=NEW.user_id AND r.id=NEW.candidate_id;
    IF release_receipt IS NULL OR missing_assets<>0
       OR release_receipt->'assets' IS DISTINCT FROM expected_assets
       OR (engine_name IN ('filmcraft','photocraft') AND (
            native_count<>1 OR missing_native<>0
            OR release_receipt->'nativeProjects' IS DISTINCT FROM expected_native))
       OR (engine_name NOT IN ('filmcraft','photocraft') AND (
            native_count<>0 OR release_receipt ? 'nativeProjects')) THEN
        RAISE EXCEPTION 'creative candidate release set is incomplete'
            USING ERRCODE='40001';
    END IF;
    RETURN NEW;
END; $$;
CREATE CONSTRAINT TRIGGER creative_candidate_release_complete_guard
    AFTER UPDATE ON creative_candidate_states DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_release_complete_guard();
