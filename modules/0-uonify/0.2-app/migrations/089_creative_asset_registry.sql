-- Shared durable registry for immutable creative media revisions. It stores
-- authority and exact GCS generations but creates no route, mount or worker.
CREATE TABLE creative_assets (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    id uuid NOT NULL,
    uonify_project_id uuid,
    current_revision integer NOT NULL CHECK (current_revision > 0),
    authorization_state text NOT NULL
        CHECK (authorization_state IN ('allowed','revoked','quarantined')),
    revoked_at timestamptz,
    state_reason text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,id),
    FOREIGN KEY (user_id,uonify_project_id)
        REFERENCES uony_projects(user_id,id) ON DELETE CASCADE,
    CHECK ((authorization_state = 'allowed' AND revoked_at IS NULL
            AND state_reason IS NULL)
        OR (authorization_state = 'revoked' AND revoked_at IS NOT NULL
            AND state_reason IS NOT NULL)
        OR (authorization_state = 'quarantined' AND revoked_at IS NULL
            AND state_reason IS NOT NULL))
);

CREATE TABLE creative_asset_revisions (
    user_id uuid NOT NULL,
    asset_id uuid NOT NULL,
    revision integer NOT NULL CHECK (revision > 0),
    role text NOT NULL CHECK (role ~ '^[a-z][a-z0-9_]{0,63}$'),
    kind text NOT NULL CHECK (kind IN ('image','video','audio')),
    mime_type text NOT NULL,
    byte_size bigint NOT NULL CHECK (byte_size > 0),
    sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    storage_bucket text NOT NULL,
    storage_name text NOT NULL,
    storage_generation bigint NOT NULL CHECK (storage_generation > 0),
    media jsonb NOT NULL CHECK (jsonb_typeof(media) = 'object'),
    lineage jsonb NOT NULL CHECK (jsonb_typeof(lineage) = 'object'),
    craft_blockers jsonb NOT NULL CHECK (jsonb_typeof(craft_blockers) = 'array'),
    source_job_id uuid NOT NULL,
    source_step_id uuid NOT NULL,
    execution_graph_sha256 text NOT NULL
        CHECK (execution_graph_sha256 ~ '^[0-9a-f]{64}$'),
    snapshot_sha256 text NOT NULL CHECK (snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,asset_id,revision),
    UNIQUE (storage_bucket,storage_name,storage_generation),
    UNIQUE (user_id,snapshot_sha256),
    FOREIGN KEY (user_id,asset_id)
        REFERENCES creative_assets(user_id,id) ON DELETE CASCADE
);

CREATE INDEX creative_assets_allowed_claim
    ON creative_assets(user_id,uonify_project_id,id,current_revision)
    WHERE authorization_state = 'allowed';
CREATE INDEX creative_asset_revisions_source
    ON creative_asset_revisions
    (user_id,source_job_id,source_step_id,execution_graph_sha256);

CREATE FUNCTION creative_asset_revision_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'creative asset revisions are immutable';
END;
$$;
CREATE TRIGGER creative_asset_revision_immutable
    BEFORE UPDATE ON creative_asset_revisions
    FOR EACH ROW EXECUTE FUNCTION creative_asset_revision_immutable();

CREATE FUNCTION creative_asset_identity_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (OLD.user_id,OLD.id,OLD.uonify_project_id,OLD.created_at)
       IS DISTINCT FROM
       (NEW.user_id,NEW.id,NEW.uonify_project_id,NEW.created_at) THEN
        RAISE EXCEPTION 'creative asset identity is immutable';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER creative_asset_identity_immutable
    BEFORE UPDATE ON creative_assets
    FOR EACH ROW EXECUTE FUNCTION creative_asset_identity_immutable();

CREATE TRIGGER account_write_allowed
    BEFORE INSERT OR UPDATE ON creative_assets
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT ON creative_asset_revisions
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
