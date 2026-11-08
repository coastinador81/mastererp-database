-- Durable candidate/review lifecycle after a fenced creative attempt.
-- No route, worker, provider call or publication consumes these rows.
ALTER TABLE creative_execution_steps
    DROP CONSTRAINT creative_execution_steps_kind_check;
ALTER TABLE creative_execution_steps
    ADD CONSTRAINT creative_execution_steps_kind_check CHECK (kind IN
        ('google_generation','storage_adopt','craft','candidate_adopt','review'));

CREATE TABLE creative_candidate_receipts (
    user_id uuid NOT NULL,
    id uuid NOT NULL,
    uonify_project_id uuid,
    job_id uuid NOT NULL,
    step_id uuid NOT NULL,
    attempt_id uuid NOT NULL,
    attempt_no integer NOT NULL CHECK (attempt_no > 0),
    lease_token uuid NOT NULL,
    fence_epoch bigint NOT NULL CHECK (fence_epoch > 0),
    admission_id uuid NOT NULL,
    admission_sha256 text NOT NULL CHECK (admission_sha256 ~ '^[0-9a-f]{64}$'),
    claim_set_sha256 text NOT NULL CHECK (claim_set_sha256 ~ '^[0-9a-f]{64}$'),
    execution_graph_sha256 text NOT NULL CHECK (execution_graph_sha256 ~ '^[0-9a-f]{64}$'),
    job_binding_sha256 text NOT NULL CHECK (job_binding_sha256 ~ '^[0-9a-f]{64}$'),
    input_manifest_sha256 text NOT NULL CHECK (input_manifest_sha256 ~ '^[0-9a-f]{64}$'),
    recipe_sha256 text NOT NULL CHECK (recipe_sha256 ~ '^[0-9a-f]{64}$'),
    adapter_plan_sha256 text NOT NULL CHECK (adapter_plan_sha256 ~ '^[0-9a-f]{64}$'),
    capability_matrix_sha256 text NOT NULL CHECK (capability_matrix_sha256 ~ '^[0-9a-f]{64}$'),
    output_manifest_sha256 text NOT NULL CHECK (output_manifest_sha256 ~ '^[0-9a-f]{64}$'),
    craft_candidate_result_sha256 text NOT NULL
        CHECK (craft_candidate_result_sha256 ~ '^[0-9a-f]{64}$'),
    candidate_content_sha256 text NOT NULL CHECK (candidate_content_sha256 ~ '^[0-9a-f]{64}$'),
    candidate_receipt_sha256 text NOT NULL CHECK (candidate_receipt_sha256 ~ '^[0-9a-f]{64}$'),
    receipt jsonb NOT NULL CHECK (jsonb_typeof(receipt) = 'object'),
    received_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,id),
    UNIQUE (user_id,attempt_id),
    UNIQUE (user_id,candidate_receipt_sha256),
    UNIQUE (user_id,id,job_id,admission_id,admission_sha256,claim_set_sha256),
    FOREIGN KEY (user_id,job_id,step_id,attempt_no,attempt_id,lease_token,
                 fence_epoch,admission_id,admission_sha256,claim_set_sha256)
        REFERENCES creative_execution_attempts
            (user_id,job_id,step_id,attempt_no,id,claim_lease_token,fence_epoch,
             admission_id,admission_sha256,claim_set_sha256) ON DELETE CASCADE,
    FOREIGN KEY (user_id,uonify_project_id)
        REFERENCES uony_projects(user_id,id) ON DELETE CASCADE
);
CREATE INDEX creative_candidate_receipts_by_project
    ON creative_candidate_receipts(user_id,uonify_project_id,id);
CREATE INDEX creative_candidate_receipts_by_job
    ON creative_candidate_receipts(user_id,job_id,id);

CREATE TABLE creative_candidate_states (
    user_id uuid NOT NULL,
    candidate_id uuid NOT NULL,
    state text NOT NULL CHECK (state IN
        ('received','quarantined','review_pending','blocked','approved_for_use',
         'revision_requested','rejected','released','discarded')),
    version integer NOT NULL DEFAULT 1 CHECK (version > 0),
    quarantine_set_sha256 text CHECK (quarantine_set_sha256 ~ '^[0-9a-f]{64}$'),
    accepted_for_use boolean NOT NULL DEFAULT false,
    publication_authorized boolean NOT NULL DEFAULT false
        CHECK (publication_authorized=false),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,candidate_id),
    FOREIGN KEY (user_id,candidate_id)
        REFERENCES creative_candidate_receipts(user_id,id) ON DELETE CASCADE,
    CHECK (accepted_for_use = (state IN ('approved_for_use','released'))),
    CHECK ((state='received' AND quarantine_set_sha256 IS NULL)
        OR (state<>'received' AND quarantine_set_sha256 IS NOT NULL))
);

CREATE TABLE creative_candidate_quarantines (
    user_id uuid NOT NULL,
    candidate_id uuid NOT NULL,
    id uuid NOT NULL,
    job_id uuid NOT NULL,
    adoption_step_id uuid NOT NULL,
    adoption_attempt_id uuid NOT NULL,
    adoption_attempt_no integer NOT NULL CHECK (adoption_attempt_no > 0),
    adoption_lease_token uuid NOT NULL,
    adoption_fence_epoch bigint NOT NULL CHECK (adoption_fence_epoch > 0),
    admission_id uuid NOT NULL,
    admission_sha256 text NOT NULL CHECK (admission_sha256 ~ '^[0-9a-f]{64}$'),
    claim_set_sha256 text NOT NULL CHECK (claim_set_sha256 ~ '^[0-9a-f]{64}$'),
    adoption_result_sha256 text NOT NULL
        CHECK (adoption_result_sha256 ~ '^[0-9a-f]{64}$'),
    quarantine_set_sha256 text NOT NULL CHECK (quarantine_set_sha256 ~ '^[0-9a-f]{64}$'),
    item_count integer NOT NULL CHECK (item_count > 0 AND item_count <= 64),
    receipt jsonb NOT NULL CHECK (jsonb_typeof(receipt)='object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,candidate_id),
    UNIQUE (user_id,id),
    UNIQUE (user_id,candidate_id,quarantine_set_sha256),
    FOREIGN KEY (user_id,candidate_id,job_id,admission_id,admission_sha256,
                 claim_set_sha256)
        REFERENCES creative_candidate_receipts
            (user_id,id,job_id,admission_id,admission_sha256,claim_set_sha256)
        ON DELETE CASCADE,
    FOREIGN KEY (user_id,job_id,adoption_step_id,adoption_attempt_no,
                 adoption_attempt_id,adoption_lease_token,adoption_fence_epoch,
                 admission_id,admission_sha256,claim_set_sha256)
        REFERENCES creative_execution_attempts
            (user_id,job_id,step_id,attempt_no,id,claim_lease_token,fence_epoch,
             admission_id,admission_sha256,claim_set_sha256)
);
CREATE INDEX creative_candidate_quarantines_by_job
    ON creative_candidate_quarantines(user_id,job_id,candidate_id);

ALTER TABLE creative_asset_revisions ADD CONSTRAINT
    creative_asset_revisions_candidate_snapshot_unique
    UNIQUE (user_id,asset_id,revision,snapshot_sha256);

CREATE TABLE creative_candidate_quarantine_assets (
    user_id uuid NOT NULL,
    candidate_id uuid NOT NULL,
    ordinal integer NOT NULL CHECK (ordinal >= 0 AND ordinal < 64),
    output_id uuid NOT NULL,
    asset_id uuid NOT NULL,
    revision integer NOT NULL CHECK (revision > 0),
    snapshot_sha256 text NOT NULL CHECK (snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    storage_receipt jsonb NOT NULL CHECK (jsonb_typeof(storage_receipt)='object'),
    item_receipt_sha256 text NOT NULL CHECK (item_receipt_sha256 ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,candidate_id,ordinal),
    UNIQUE (user_id,candidate_id,output_id),
    UNIQUE (user_id,candidate_id,asset_id,revision),
    FOREIGN KEY (user_id,candidate_id)
        REFERENCES creative_candidate_quarantines(user_id,candidate_id) ON DELETE CASCADE,
    FOREIGN KEY (user_id,asset_id,revision,snapshot_sha256)
        REFERENCES creative_asset_revisions
            (user_id,asset_id,revision,snapshot_sha256)
);

CREATE TABLE creative_candidate_evaluations (
    user_id uuid NOT NULL,
    id uuid NOT NULL,
    candidate_id uuid NOT NULL,
    quarantine_set_sha256 text NOT NULL CHECK (quarantine_set_sha256 ~ '^[0-9a-f]{64}$'),
    evaluator text NOT NULL,
    policy_sha256 text NOT NULL CHECK (policy_sha256 ~ '^[0-9a-f]{64}$'),
    evaluation_sha256 text NOT NULL CHECK (evaluation_sha256 ~ '^[0-9a-f]{64}$'),
    automatic_passed boolean NOT NULL,
    ready_for_human_review boolean NOT NULL,
    receipt jsonb NOT NULL CHECK (jsonb_typeof(receipt)='object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,id),
    UNIQUE (user_id,candidate_id,evaluation_sha256),
    UNIQUE (user_id,id,candidate_id),
    UNIQUE (user_id,id,candidate_id,quarantine_set_sha256),
    FOREIGN KEY (user_id,candidate_id,quarantine_set_sha256)
        REFERENCES creative_candidate_quarantines
            (user_id,candidate_id,quarantine_set_sha256) ON DELETE CASCADE
);

CREATE TABLE creative_candidate_reviews (
    user_id uuid NOT NULL,
    id uuid NOT NULL,
    candidate_id uuid NOT NULL,
    evaluation_id uuid NOT NULL,
    reviewer uuid NOT NULL,
    decision text NOT NULL CHECK (decision IN
        ('approved_for_use','revision_requested','rejected')),
    review_sha256 text NOT NULL CHECK (review_sha256 ~ '^[0-9a-f]{64}$'),
    receipt jsonb NOT NULL CHECK (jsonb_typeof(receipt)='object'),
    publication_authorized boolean NOT NULL DEFAULT false
        CHECK (publication_authorized=false),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,id),
    UNIQUE (user_id,candidate_id,review_sha256),
    UNIQUE (user_id,id,candidate_id,evaluation_id),
    FOREIGN KEY (user_id,candidate_id)
        REFERENCES creative_candidate_receipts(user_id,id) ON DELETE CASCADE,
    FOREIGN KEY (user_id,evaluation_id,candidate_id)
        REFERENCES creative_candidate_evaluations(user_id,id,candidate_id),
    FOREIGN KEY (reviewer) REFERENCES users(id),
    CHECK (reviewer=user_id)
);

CREATE TABLE creative_candidate_releases (
    user_id uuid NOT NULL,
    id uuid NOT NULL,
    candidate_id uuid NOT NULL,
    evaluation_id uuid NOT NULL,
    review_id uuid NOT NULL,
    actor_id uuid NOT NULL,
    quarantine_set_sha256 text NOT NULL CHECK (quarantine_set_sha256 ~ '^[0-9a-f]{64}$'),
    asset_set_sha256 text NOT NULL CHECK (asset_set_sha256 ~ '^[0-9a-f]{64}$'),
    release_sha256 text NOT NULL CHECK (release_sha256 ~ '^[0-9a-f]{64}$'),
    receipt jsonb NOT NULL CHECK (jsonb_typeof(receipt)='object'),
    publication_authorized boolean NOT NULL DEFAULT false
        CHECK (publication_authorized=false),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,id),
    UNIQUE (user_id,candidate_id),
    FOREIGN KEY (user_id,candidate_id,quarantine_set_sha256)
        REFERENCES creative_candidate_quarantines
            (user_id,candidate_id,quarantine_set_sha256) ON DELETE CASCADE,
    FOREIGN KEY (user_id,evaluation_id,candidate_id,quarantine_set_sha256)
        REFERENCES creative_candidate_evaluations
            (user_id,id,candidate_id,quarantine_set_sha256),
    FOREIGN KEY (user_id,review_id,candidate_id,evaluation_id)
        REFERENCES creative_candidate_reviews(user_id,id,candidate_id,evaluation_id),
    FOREIGN KEY (actor_id) REFERENCES users(id),
    CHECK (actor_id=user_id)
);

CREATE FUNCTION creative_candidate_receipt_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
    RAISE EXCEPTION 'creative candidate receipts are immutable';
END; $$;

CREATE TRIGGER creative_candidate_receipt_immutable
    BEFORE UPDATE ON creative_candidate_receipts
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_receipt_immutable();
CREATE TRIGGER creative_candidate_quarantine_immutable
    BEFORE UPDATE ON creative_candidate_quarantines
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_receipt_immutable();
CREATE TRIGGER creative_candidate_quarantine_asset_immutable
    BEFORE UPDATE ON creative_candidate_quarantine_assets
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_receipt_immutable();
CREATE TRIGGER creative_candidate_evaluation_immutable
    BEFORE UPDATE ON creative_candidate_evaluations
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_receipt_immutable();
CREATE TRIGGER creative_candidate_review_immutable
    BEFORE UPDATE ON creative_candidate_reviews
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_receipt_immutable();
CREATE TRIGGER creative_candidate_release_immutable
    BEFORE UPDATE ON creative_candidate_releases
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_receipt_immutable();

CREATE FUNCTION creative_candidate_state_identity_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
    IF (OLD.user_id,OLD.candidate_id,OLD.publication_authorized)
       IS DISTINCT FROM
       (NEW.user_id,NEW.candidate_id,NEW.publication_authorized) THEN
        RAISE EXCEPTION 'creative candidate state identity is immutable';
    END IF;
    IF NEW.version <> OLD.version + 1 THEN
        RAISE EXCEPTION 'creative candidate state requires exact CAS version';
    END IF;
    IF NOT ((OLD.state='received' AND NEW.state IN ('quarantined','discarded'))
        OR (OLD.state='quarantined'
            AND NEW.state IN ('review_pending','blocked','discarded'))
        OR (OLD.state='review_pending'
            AND NEW.state IN ('approved_for_use','revision_requested','rejected'))
        OR (OLD.state='approved_for_use' AND NEW.state='released')) THEN
        RAISE EXCEPTION 'creative candidate state transition is not allowed';
    END IF;
    IF OLD.quarantine_set_sha256 IS NOT NULL
       AND OLD.quarantine_set_sha256 IS DISTINCT FROM NEW.quarantine_set_sha256 THEN
        RAISE EXCEPTION 'creative candidate quarantine identity is immutable';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER creative_candidate_state_identity_immutable
    BEFORE UPDATE ON creative_candidate_states
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_state_identity_immutable();

CREATE TRIGGER account_write_allowed
    BEFORE INSERT ON creative_candidate_receipts
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT OR UPDATE ON creative_candidate_states
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT ON creative_candidate_quarantines
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT ON creative_candidate_quarantine_assets
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT ON creative_candidate_evaluations
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT ON creative_candidate_reviews
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT ON creative_candidate_releases
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
