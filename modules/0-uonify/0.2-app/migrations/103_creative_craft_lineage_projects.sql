-- Durable Craft source edges and create-only native projects.
-- This migration is inactive until the private creative lifecycle is wired.

CREATE TABLE creative_asset_lineage_sources (
    user_id uuid NOT NULL,
    output_asset_id uuid NOT NULL,
    output_revision integer NOT NULL CHECK (output_revision > 0),
    ordinal integer NOT NULL CHECK (ordinal >= 0 AND ordinal < 64),
    source_asset_id uuid NOT NULL,
    source_revision integer NOT NULL CHECK (source_revision > 0),
    source_snapshot_sha256 text NOT NULL
        CHECK (source_snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    relation text NOT NULL DEFAULT 'media_input'
        CHECK (relation='media_input'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,output_asset_id,output_revision,ordinal),
    UNIQUE (user_id,output_asset_id,output_revision,
            source_asset_id,source_revision),
    FOREIGN KEY (user_id,output_asset_id,output_revision)
        REFERENCES creative_asset_revisions(user_id,asset_id,revision)
        ON DELETE CASCADE,
    FOREIGN KEY (user_id,source_asset_id,source_revision,
                 source_snapshot_sha256)
        REFERENCES creative_asset_revisions
            (user_id,asset_id,revision,snapshot_sha256),
    CHECK ((output_asset_id,output_revision)
           <> (source_asset_id,source_revision))
);
CREATE INDEX creative_asset_lineage_by_source
    ON creative_asset_lineage_sources
       (user_id,source_asset_id,source_revision,output_asset_id);

CREATE FUNCTION creative_asset_lineage_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE output_project uuid;
DECLARE source_project uuid;
DECLARE source_state text;
DECLARE source_current integer;
DECLARE creates_cycle boolean;
BEGIN
    SELECT uonify_project_id INTO output_project
      FROM creative_assets
     WHERE user_id=NEW.user_id AND id=NEW.output_asset_id FOR SHARE;
    SELECT uonify_project_id,authorization_state,current_revision
      INTO source_project,source_state,source_current
      FROM creative_assets
     WHERE user_id=NEW.user_id AND id=NEW.source_asset_id FOR SHARE;
    IF output_project IS DISTINCT FROM source_project
       OR source_state IS DISTINCT FROM 'allowed'
       OR source_current IS DISTINCT FROM NEW.source_revision THEN
        RAISE EXCEPTION 'creative lineage source scope is not allowed';
    END IF;
    WITH RECURSIVE ancestry(asset_id,revision) AS (
        SELECT source_asset_id,source_revision
          FROM creative_asset_lineage_sources
         WHERE user_id=NEW.user_id
           AND output_asset_id=NEW.source_asset_id
           AND output_revision=NEW.source_revision
        UNION
        SELECT edge.source_asset_id,edge.source_revision
          FROM creative_asset_lineage_sources edge
          JOIN ancestry parent
            ON parent.asset_id=edge.output_asset_id
           AND parent.revision=edge.output_revision
         WHERE edge.user_id=NEW.user_id
    )
    SELECT EXISTS(SELECT 1 FROM ancestry
                   WHERE asset_id=NEW.output_asset_id
                     AND revision=NEW.output_revision)
      INTO creates_cycle;
    IF creates_cycle THEN
        RAISE EXCEPTION 'creative asset lineage cycle is forbidden';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER creative_asset_lineage_guard
    BEFORE INSERT ON creative_asset_lineage_sources
    FOR EACH ROW EXECUTE FUNCTION creative_asset_lineage_guard();
CREATE TRIGGER creative_asset_lineage_immutable
    BEFORE UPDATE ON creative_asset_lineage_sources
    FOR EACH ROW EXECUTE FUNCTION creative_asset_revision_immutable();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT ON creative_asset_lineage_sources
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();

CREATE TABLE creative_native_projects (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    id uuid NOT NULL,
    uonify_project_id uuid,
    current_revision integer NOT NULL CHECK (current_revision=1),
    authorization_state text NOT NULL
        CHECK (authorization_state IN ('quarantined','allowed','revoked')),
    state_reason text,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,id),
    FOREIGN KEY (user_id,uonify_project_id)
        REFERENCES uony_projects(user_id,id) ON DELETE CASCADE,
    CHECK ((authorization_state='quarantined' AND state_reason IS NOT NULL
            AND revoked_at IS NULL)
        OR (authorization_state='allowed' AND state_reason IS NULL
            AND revoked_at IS NULL)
        OR (authorization_state='revoked' AND state_reason IS NOT NULL
            AND revoked_at IS NOT NULL))
);

CREATE TABLE creative_native_project_revisions (
    user_id uuid NOT NULL,
    project_id uuid NOT NULL,
    revision integer NOT NULL CHECK (revision=1),
    engine text NOT NULL CHECK (engine IN ('filmcraft','photocraft')),
    operation text NOT NULL,
    mime_type text NOT NULL CHECK (mime_type IN
        ('application/json','application/zip')),
    byte_size bigint NOT NULL CHECK (byte_size > 0),
    sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    storage_bucket text NOT NULL,
    storage_name text NOT NULL,
    storage_generation bigint NOT NULL CHECK (storage_generation > 0),
    lineage jsonb NOT NULL CHECK (jsonb_typeof(lineage)='object'),
    input_claim_set_sha256 text NOT NULL
        CHECK (input_claim_set_sha256 ~ '^[0-9a-f]{64}$'),
    source_job_id uuid NOT NULL,
    source_step_id uuid NOT NULL,
    execution_graph_sha256 text NOT NULL
        CHECK (execution_graph_sha256 ~ '^[0-9a-f]{64}$'),
    candidate_id uuid NOT NULL,
    snapshot_sha256 text NOT NULL CHECK (snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,project_id,revision),
    UNIQUE (storage_bucket,storage_name,storage_generation),
    UNIQUE (user_id,snapshot_sha256),
    UNIQUE (user_id,project_id,revision,snapshot_sha256),
    UNIQUE (user_id,project_id,revision,snapshot_sha256,candidate_id),
    FOREIGN KEY (user_id,project_id)
        REFERENCES creative_native_projects(user_id,id) ON DELETE CASCADE,
    FOREIGN KEY (user_id,candidate_id)
        REFERENCES creative_candidate_receipts(user_id,id) ON DELETE CASCADE,
    FOREIGN KEY (user_id,source_job_id,source_step_id)
        REFERENCES creative_execution_steps(user_id,job_id,step_id)
);

CREATE TABLE creative_native_project_lineage_sources (
    user_id uuid NOT NULL,
    project_id uuid NOT NULL,
    project_revision integer NOT NULL CHECK (project_revision=1),
    ordinal integer NOT NULL CHECK (ordinal >= 0 AND ordinal < 64),
    source_asset_id uuid NOT NULL,
    source_revision integer NOT NULL CHECK (source_revision > 0),
    source_snapshot_sha256 text NOT NULL
        CHECK (source_snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,project_id,project_revision,ordinal),
    UNIQUE (user_id,project_id,project_revision,
            source_asset_id,source_revision),
    FOREIGN KEY (user_id,project_id,project_revision)
        REFERENCES creative_native_project_revisions
            (user_id,project_id,revision) ON DELETE CASCADE,
    FOREIGN KEY (user_id,source_asset_id,source_revision,
                 source_snapshot_sha256)
        REFERENCES creative_asset_revisions
            (user_id,asset_id,revision,snapshot_sha256)
);

CREATE FUNCTION creative_native_project_lineage_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE target_scope uuid;
DECLARE source_scope uuid;
DECLARE source_state text;
DECLARE source_current integer;
BEGIN
    SELECT uonify_project_id INTO target_scope
      FROM creative_native_projects
     WHERE user_id=NEW.user_id AND id=NEW.project_id FOR SHARE;
    SELECT uonify_project_id,authorization_state,current_revision
      INTO source_scope,source_state,source_current
      FROM creative_assets
     WHERE user_id=NEW.user_id AND id=NEW.source_asset_id FOR SHARE;
    IF target_scope IS DISTINCT FROM source_scope
       OR source_state IS DISTINCT FROM 'allowed'
       OR source_current IS DISTINCT FROM NEW.source_revision THEN
        RAISE EXCEPTION 'creative native project source is not allowed';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER creative_native_project_lineage_guard
    BEFORE INSERT ON creative_native_project_lineage_sources
    FOR EACH ROW EXECUTE FUNCTION creative_native_project_lineage_guard();

CREATE TABLE creative_candidate_native_projects (
    user_id uuid NOT NULL,
    candidate_id uuid NOT NULL,
    project_id uuid NOT NULL,
    revision integer NOT NULL CHECK (revision=1),
    snapshot_sha256 text NOT NULL CHECK (snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    item_receipt_sha256 text NOT NULL
        CHECK (item_receipt_sha256 ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,candidate_id),
    UNIQUE (user_id,project_id,revision),
    FOREIGN KEY (user_id,candidate_id)
        REFERENCES creative_candidate_quarantines(user_id,candidate_id)
        ON DELETE CASCADE,
    FOREIGN KEY (user_id,project_id,revision,snapshot_sha256,candidate_id)
        REFERENCES creative_native_project_revisions
            (user_id,project_id,revision,snapshot_sha256,candidate_id)
);


CREATE FUNCTION creative_candidate_native_project_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE native_candidate uuid;
DECLARE candidate_project uuid;
DECLARE native_project_scope uuid;
DECLARE declared_sources jsonb;
DECLARE persisted_sources jsonb;
BEGIN
    SELECT r.candidate_id,r.lineage->'sources',p.uonify_project_id,
           c.uonify_project_id,
           (SELECT jsonb_agg(jsonb_build_object(
                'assetId',edge.source_asset_id::text,
                'revision',edge.source_revision,
                'snapshotSha256',edge.source_snapshot_sha256)
                ORDER BY edge.ordinal)
              FROM creative_native_project_lineage_sources edge
             WHERE edge.user_id=NEW.user_id
               AND edge.project_id=NEW.project_id
               AND edge.project_revision=NEW.revision)
      INTO native_candidate,declared_sources,native_project_scope,
           candidate_project,persisted_sources
      FROM creative_native_project_revisions r
      JOIN creative_native_projects p
        ON p.user_id=r.user_id AND p.id=r.project_id
      JOIN creative_candidate_receipts c
        ON c.user_id=NEW.user_id AND c.id=NEW.candidate_id
     WHERE r.user_id=NEW.user_id AND r.project_id=NEW.project_id
       AND r.revision=NEW.revision;
    IF native_candidate IS DISTINCT FROM NEW.candidate_id
       OR native_project_scope IS DISTINCT FROM candidate_project
       OR persisted_sources IS NULL
       OR persisted_sources IS DISTINCT FROM declared_sources THEN
        RAISE EXCEPTION 'creative candidate native project is not exact';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER creative_candidate_native_project_guard
    BEFORE INSERT ON creative_candidate_native_projects
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_native_project_guard();

CREATE FUNCTION creative_candidate_quarantine_complete_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE engine_name text;
DECLARE quarantine_row record;
DECLARE native_count integer;
DECLARE native_item jsonb;
DECLARE provider_native jsonb;
BEGIN
    IF OLD.state<>'received' OR NEW.state<>'quarantined' THEN
        RETURN NEW;
    END IF;
    SELECT r.receipt->'engine'->>'name' INTO engine_name
      FROM creative_candidate_receipts r
     WHERE r.user_id=NEW.user_id AND r.id=NEW.candidate_id;
    SELECT q.* INTO quarantine_row
      FROM creative_candidate_quarantines q
     WHERE q.user_id=NEW.user_id AND q.candidate_id=NEW.candidate_id;
    SELECT count(*) INTO native_count
      FROM creative_candidate_native_projects l
     WHERE l.user_id=NEW.user_id AND l.candidate_id=NEW.candidate_id;
    SELECT jsonb_build_object(
        'projectId',l.project_id::text,'revision',l.revision,
        'snapshotSha256',l.snapshot_sha256,
        'storageReceipt',jsonb_build_object(
            'bucket',v.storage_bucket,'name',v.storage_name,
            'generation',v.storage_generation,'mimeType',v.mime_type,
            'byteSize',v.byte_size,'sha256',v.sha256),
        'itemReceiptSha256',l.item_receipt_sha256)
      INTO native_item
      FROM creative_candidate_native_projects l
      JOIN creative_native_project_revisions v
        ON v.user_id=l.user_id AND v.project_id=l.project_id
       AND v.revision=l.revision
     WHERE l.user_id=NEW.user_id AND l.candidate_id=NEW.candidate_id
     LIMIT 1;
    SELECT t.result_receipt->'nativeProjectReceipt'
      INTO provider_native
      FROM creative_execution_attempts t
     WHERE t.user_id=NEW.user_id
       AND t.id=quarantine_row.adoption_attempt_id;
    IF engine_name IN ('filmcraft','photocraft') THEN
        IF native_count<>1
           OR quarantine_row.receipt->>'schemaVersion'<>'2'
           OR quarantine_row.receipt->'nativeProject' IS DISTINCT FROM native_item
           OR provider_native IS DISTINCT FROM
              (native_item - 'snapshotSha256' - 'storageReceipt'
               - 'itemReceiptSha256') || jsonb_build_object(
                    'receipt',native_item->'storageReceipt')
           OR quarantine_row.receipt->>'quarantineSetSha256'
              IS DISTINCT FROM quarantine_row.quarantine_set_sha256 THEN
            RAISE EXCEPTION 'creative native quarantine is incomplete';
        END IF;
    ELSIF native_count<>0 OR quarantine_row.receipt ? 'nativeProject'
       OR provider_native IS NOT NULL THEN
        RAISE EXCEPTION 'creative native quarantine is not allowed';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER creative_candidate_quarantine_complete_guard
    BEFORE UPDATE ON creative_candidate_states
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_quarantine_complete_guard();

CREATE TRIGGER creative_native_project_revision_immutable
    BEFORE UPDATE ON creative_native_project_revisions
    FOR EACH ROW EXECUTE FUNCTION creative_asset_revision_immutable();
CREATE TRIGGER creative_candidate_native_project_immutable
    BEFORE UPDATE ON creative_candidate_native_projects
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_receipt_immutable();
CREATE TRIGGER creative_native_project_lineage_immutable
    BEFORE UPDATE ON creative_native_project_lineage_sources
    FOR EACH ROW EXECUTE FUNCTION creative_asset_revision_immutable();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT OR UPDATE ON creative_native_projects
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT ON creative_native_project_revisions
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT ON creative_candidate_native_projects
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT ON creative_native_project_lineage_sources
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();

CREATE FUNCTION creative_native_project_identity_guard() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
    IF (OLD.user_id,OLD.id,OLD.uonify_project_id,OLD.current_revision,
        OLD.created_at) IS DISTINCT FROM
       (NEW.user_id,NEW.id,NEW.uonify_project_id,NEW.current_revision,
        NEW.created_at) THEN
        RAISE EXCEPTION 'creative native project identity is immutable';
    END IF;
    IF current_user='uonify_creative_reviewer' THEN
        IF NOT (OLD.authorization_state='quarantined'
                AND NEW.authorization_state='allowed'
                AND NEW.state_reason IS NULL AND NEW.revoked_at IS NULL) THEN
            RAISE EXCEPTION 'creative reviewer native project transition denied'
                USING ERRCODE='42501';
        END IF;
    ELSIF OLD.authorization_state='quarantined'
       AND NEW.authorization_state='allowed' THEN
        RAISE EXCEPTION 'creative reviewer role required' USING ERRCODE='42501';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER creative_native_project_identity_guard
    BEFORE UPDATE ON creative_native_projects
    FOR EACH ROW EXECUTE FUNCTION creative_native_project_identity_guard();

GRANT SELECT ON creative_asset_lineage_sources,creative_native_projects,
    creative_native_project_revisions,creative_native_project_lineage_sources,
    creative_candidate_native_projects TO uonify_creative_reviewer;
GRANT UPDATE (authorization_state,state_reason,updated_at)
    ON creative_native_projects TO uonify_creative_reviewer;
REVOKE ALL ON creative_asset_lineage_sources,creative_native_projects,
    creative_native_project_revisions,creative_native_project_lineage_sources,
    creative_candidate_native_projects
    FROM PUBLIC,uonify_app_runtime;
