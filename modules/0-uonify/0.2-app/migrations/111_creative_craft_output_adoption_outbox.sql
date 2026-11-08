-- Durable, inactive escrow -> private adoption -> launcher-cleanup
-- reconciliation workflow.
-- This migration exposes no route and starts no worker.  Every row is bound
-- to one exact Launcher V2 reservation and one exact Craft candidate.

CREATE TABLE creative_craft_output_adoption_outbox (
    user_id uuid NOT NULL,
    escrow_id uuid NOT NULL,
    source_attempt_id uuid NOT NULL,
    candidate_id uuid NOT NULL,
    job_id uuid NOT NULL,
    source_step_id uuid NOT NULL,
    attempt_no integer NOT NULL CHECK (attempt_no > 0),
    claim_lease_token uuid NOT NULL,
    fence_epoch bigint NOT NULL CHECK (fence_epoch > 0),
    admission_sha256 text NOT NULL
        CHECK (admission_sha256 ~ '^[0-9a-f]{64}$'),
    claim_set_sha256 text NOT NULL
        CHECK (claim_set_sha256 ~ '^[0-9a-f]{64}$'),
    kind text NOT NULL DEFAULT 'craft' CHECK (kind='craft'),
    provider_call boolean NOT NULL DEFAULT true CHECK (provider_call),
    terminal_status text NOT NULL DEFAULT 'succeeded'
        CHECK (terminal_status='succeeded'),
    dispatch_id uuid NOT NULL,
    request_sha256 text NOT NULL
        CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
    authority_sha256 text NOT NULL
        CHECK (authority_sha256 ~ '^[0-9a-f]{64}$'),
    candidate_result_sha256 text NOT NULL
        CHECK (candidate_result_sha256 ~ '^[0-9a-f]{64}$'),
    artifact_manifest_sha256 text NOT NULL
        CHECK (artifact_manifest_sha256 ~ '^[0-9a-f]{64}$'),
    escrow_manifest_sha256 text NOT NULL
        CHECK (escrow_manifest_sha256 ~ '^[0-9a-f]{64}$'),
    escrow_manifest jsonb NOT NULL
        CHECK (jsonb_typeof(escrow_manifest)='object'),
    engine text NOT NULL
        CHECK (engine IN ('filmcraft','effectcraft','photocraft')),
    state text NOT NULL DEFAULT 'pending_adoption'
        CHECK (state IN ('pending_adoption','adopting','adopted',
                         'reconciliation_pending','reconciling_cleanup',
                         'deleted')),
    version integer NOT NULL DEFAULT 1 CHECK (version > 0),
    lease_token uuid,
    lease_until timestamptz,
    attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    quarantine_set_sha256 text
        CHECK (quarantine_set_sha256 ~ '^[0-9a-f]{64}$'),
    adoption_manifest_sha256 text
        CHECK (adoption_manifest_sha256 ~ '^[0-9a-f]{64}$'),
    adoption_attempt_id uuid,
    adoption_fence_epoch bigint CHECK (adoption_fence_epoch > 0),
    adoption_result_sha256 text
        CHECK (adoption_result_sha256 ~ '^[0-9a-f]{64}$'),
    cleanup_receipt jsonb,
    cleanup_receipt_sha256 text
        CHECK (cleanup_receipt_sha256 ~ '^[0-9a-f]{64}$'),
    last_error text,
    available_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    adopted_at timestamptz,
    completed_at timestamptz,
    PRIMARY KEY (user_id,escrow_id),
    UNIQUE (user_id,source_attempt_id),
    UNIQUE (user_id,candidate_id),
    UNIQUE (escrow_manifest_sha256),
    FOREIGN KEY (user_id,source_attempt_id,job_id,source_step_id,attempt_no,
                 claim_lease_token,fence_epoch,admission_sha256,
                 claim_set_sha256,dispatch_id,request_sha256,authority_sha256)
        REFERENCES creative_craft_launcher_reservations
            (user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,
             fence_epoch,admission_sha256,claim_set_sha256,dispatch_id,
             request_sha256,authority_sha256),
    FOREIGN KEY (user_id,source_attempt_id,job_id,source_step_id,attempt_no,
                 claim_lease_token,fence_epoch,admission_sha256,
                 claim_set_sha256,kind,provider_call,terminal_status)
        REFERENCES creative_runtime_reconciliation_outbox
            (user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,
             fence_epoch,admission_sha256,claim_set_sha256,kind,provider_call,
             terminal_status),
    FOREIGN KEY (user_id,candidate_id,source_attempt_id)
        REFERENCES creative_candidate_receipts(user_id,id,attempt_id),
    FOREIGN KEY (user_id,candidate_id,quarantine_set_sha256,
                 adoption_attempt_id,adoption_fence_epoch,
                 adoption_result_sha256)
        REFERENCES creative_candidate_quarantines
            (user_id,candidate_id,quarantine_set_sha256,
             adoption_attempt_id,adoption_fence_epoch,adoption_result_sha256),
    CHECK ((state IN ('adopting','reconciling_cleanup')) =
           (lease_token IS NOT NULL)),
    CHECK ((state IN ('adopting','reconciling_cleanup')) =
           (lease_until IS NOT NULL)),
    CHECK ((state IN ('adopted','reconciliation_pending',
                      'reconciling_cleanup','deleted')) =
           (adoption_manifest_sha256 IS NOT NULL)),
    CHECK ((state IN ('adopted','reconciliation_pending',
                      'reconciling_cleanup','deleted')) =
           (quarantine_set_sha256 IS NOT NULL)),
    CHECK ((state IN ('adopted','reconciliation_pending',
                      'reconciling_cleanup','deleted')) =
           (adoption_attempt_id IS NOT NULL)),
    CHECK ((state IN ('adopted','reconciliation_pending',
                      'reconciling_cleanup','deleted')) =
           (adoption_fence_epoch IS NOT NULL)),
    CHECK ((state IN ('adopted','reconciliation_pending',
                      'reconciling_cleanup','deleted')) =
           (adoption_result_sha256 IS NOT NULL)),
    CHECK ((state='deleted') = (cleanup_receipt IS NOT NULL)),
    CHECK ((state='deleted') = (cleanup_receipt_sha256 IS NOT NULL)),
    CHECK ((state='deleted') = (completed_at IS NOT NULL)),
    CHECK (cleanup_receipt IS NULL OR jsonb_typeof(cleanup_receipt)='object')
);

CREATE INDEX creative_craft_output_adoption_pending
    ON creative_craft_output_adoption_outbox
       (state,available_at,lease_until,created_at)
    WHERE state IN ('pending_adoption','adopting','reconciliation_pending',
                    'reconciling_cleanup');

CREATE FUNCTION creative_craft_output_adoption_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (OLD.user_id,OLD.escrow_id,OLD.source_attempt_id,OLD.candidate_id,
        OLD.job_id,OLD.source_step_id,OLD.attempt_no,OLD.claim_lease_token,
        OLD.fence_epoch,OLD.admission_sha256,OLD.claim_set_sha256,
        OLD.kind,OLD.provider_call,OLD.terminal_status,
        OLD.dispatch_id,OLD.request_sha256,OLD.authority_sha256,
        OLD.candidate_result_sha256,OLD.artifact_manifest_sha256,
        OLD.escrow_manifest_sha256,OLD.escrow_manifest,OLD.engine,
        OLD.created_at) IS DISTINCT FROM
       (NEW.user_id,NEW.escrow_id,NEW.source_attempt_id,NEW.candidate_id,
        NEW.job_id,NEW.source_step_id,NEW.attempt_no,NEW.claim_lease_token,
        NEW.fence_epoch,NEW.admission_sha256,NEW.claim_set_sha256,
        NEW.kind,NEW.provider_call,NEW.terminal_status,
        NEW.dispatch_id,NEW.request_sha256,NEW.authority_sha256,
        NEW.candidate_result_sha256,NEW.artifact_manifest_sha256,
        NEW.escrow_manifest_sha256,NEW.escrow_manifest,NEW.engine,
        NEW.created_at) THEN
        RAISE EXCEPTION 'creative craft escrow identity is immutable';
    END IF;
    IF NEW.version <> OLD.version + 1
       OR NEW.attempt_count < OLD.attempt_count THEN
        RAISE EXCEPTION 'creative craft escrow requires exact monotonic CAS';
    END IF;
    IF OLD.state='deleted' THEN
        RAISE EXCEPTION 'terminal creative craft escrow is immutable';
    END IF;
    IF OLD.state IN ('adopted','reconciliation_pending',
                     'reconciling_cleanup') AND
       (OLD.quarantine_set_sha256,OLD.adoption_manifest_sha256,
        OLD.adoption_attempt_id,OLD.adoption_fence_epoch,
        OLD.adoption_result_sha256,OLD.adopted_at)
       IS DISTINCT FROM
       (NEW.quarantine_set_sha256,NEW.adoption_manifest_sha256,
        NEW.adoption_attempt_id,NEW.adoption_fence_epoch,
        NEW.adoption_result_sha256,NEW.adopted_at)
    THEN
        RAISE EXCEPTION 'creative craft adoption evidence is immutable';
    END IF;
    IF OLD.state='adopted' AND NEW.state='adopted' AND
       (NEW.attempt_count <> OLD.attempt_count OR
        NEW.lease_token IS NOT NULL OR NEW.lease_until IS NOT NULL)
    THEN
        RAISE EXCEPTION 'creative craft adopted deferral is metadata-only';
    END IF;
    IF NOT (
        (OLD.state='pending_adoption' AND NEW.state='adopting') OR
        (OLD.state='adopting' AND NEW.state IN
            ('adopting','pending_adoption','adopted')) OR
        (OLD.state='adopted' AND NEW.state='adopted') OR
        (OLD.state='adopted' AND NEW.state='reconciliation_pending') OR
        (OLD.state='reconciliation_pending' AND
            NEW.state='reconciling_cleanup') OR
        (OLD.state='reconciling_cleanup' AND NEW.state IN
            ('reconciling_cleanup','reconciliation_pending','deleted'))
    ) THEN
        RAISE EXCEPTION 'invalid creative craft escrow transition';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER creative_craft_output_adoption_guard
    BEFORE UPDATE ON creative_craft_output_adoption_outbox
    FOR EACH ROW EXECUTE FUNCTION creative_craft_output_adoption_guard();

CREATE FUNCTION creative_craft_output_adoption_write_allowed()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE deleting timestamptz;
BEGIN
    SELECT deletion_requested_at INTO deleting FROM users WHERE id=NEW.user_id;
    IF deleting IS NULL OR TG_OP='UPDATE' THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'Account deletion pending' USING ERRCODE='55000';
END;
$$;

CREATE TRIGGER account_write_allowed
    BEFORE INSERT OR UPDATE ON creative_craft_output_adoption_outbox
    FOR EACH ROW EXECUTE FUNCTION creative_craft_output_adoption_write_allowed();

REVOKE ALL ON creative_craft_output_adoption_outbox
    FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,
         uonify_creative_evaluator,uonify_creative_reviewer,
         uonify_craft_launcher_preparer,uonify_craft_launcher_ack_worker,
         uonify_craft_escrow_worker;

REVOKE ALL ON FUNCTION creative_craft_output_adoption_guard(),
    creative_craft_output_adoption_write_allowed()
    FROM PUBLIC,uonify_app_runtime,uonify_creative_inspector,
         uonify_creative_evaluator,uonify_creative_reviewer,
         uonify_craft_launcher_preparer,uonify_craft_launcher_ack_worker,
         uonify_craft_escrow_worker;
