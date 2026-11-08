-- Server-owned Craft launcher authority, durable reserve receipt and delayed
-- cleanup ACK.  This migration is storage only: it does not enable a route,
-- worker, launcher socket or provider dispatch.

ALTER TABLE creative_runtime_reconciliation_outbox
    ADD CONSTRAINT creative_runtime_reconciliation_exact_unique UNIQUE
        (user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,
         fence_epoch,admission_sha256,claim_set_sha256,kind,provider_call,
         terminal_status);

ALTER TABLE creative_candidate_receipts
    ADD CONSTRAINT creative_candidate_receipt_source_attempt_unique UNIQUE
        (user_id,id,attempt_id);

ALTER TABLE creative_candidate_quarantines
    ADD CONSTRAINT creative_candidate_quarantine_adoption_unique UNIQUE
        (user_id,candidate_id,quarantine_set_sha256,adoption_attempt_id,
         adoption_fence_epoch,adoption_result_sha256);

CREATE TABLE creative_craft_launcher_reservations (
    user_id uuid NOT NULL,
    attempt_id uuid NOT NULL,
    job_id uuid NOT NULL,
    step_id uuid NOT NULL,
    attempt_no integer NOT NULL CHECK (attempt_no > 0),
    claim_lease_token uuid NOT NULL,
    fence_epoch bigint NOT NULL CHECK (fence_epoch > 0),
    admission_id uuid NOT NULL,
    admission_sha256 text NOT NULL
        CHECK (admission_sha256 ~ '^[0-9a-f]{64}$'),
    claim_set_sha256 text NOT NULL
        CHECK (claim_set_sha256 ~ '^[0-9a-f]{64}$'),
    dispatch_id uuid NOT NULL,
    request_sha256 text NOT NULL
        CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
    request_authority jsonb NOT NULL
        CHECK (jsonb_typeof(request_authority)='object'),
    profile_id text NOT NULL CHECK (profile_id ~ '^[a-z][a-z0-9._-]{1,127}$'),
    profile_sha256 text NOT NULL
        CHECK (profile_sha256 ~ '^[0-9a-f]{64}$'),
    control_document jsonb NOT NULL
        CHECK (jsonb_typeof(control_document)='object'),
    input_root text NOT NULL CHECK (length(input_root) BETWEEN 1 AND 4096),
    output_root text NOT NULL CHECK (length(output_root) BETWEEN 1 AND 4096),
    inputs jsonb NOT NULL CHECK (jsonb_typeof(inputs)='array'),
    expected_outputs jsonb NOT NULL CHECK (jsonb_typeof(expected_outputs)='array'),
    limits jsonb NOT NULL CHECK (jsonb_typeof(limits)='object'),
    authority_sha256 text NOT NULL
        CHECK (authority_sha256 ~ '^[0-9a-f]{64}$'),
    reservation_receipt jsonb,
    reservation_receipt_sha256 text
        CHECK (reservation_receipt_sha256 ~ '^[0-9a-f]{64}$'),
    reserved_at timestamptz,
    prepared_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,attempt_id),
    UNIQUE (dispatch_id),
    UNIQUE (request_sha256),
    UNIQUE (user_id,attempt_id,job_id,step_id,attempt_no,claim_lease_token,
            fence_epoch,admission_sha256,claim_set_sha256,dispatch_id,
            request_sha256,authority_sha256),
    FOREIGN KEY (user_id,job_id,step_id,attempt_no,attempt_id,
                 claim_lease_token,fence_epoch,admission_id,
                 admission_sha256,claim_set_sha256)
        REFERENCES creative_execution_attempts
            (user_id,job_id,step_id,attempt_no,id,claim_lease_token,
             fence_epoch,admission_id,admission_sha256,claim_set_sha256),
    CHECK (input_root<>output_root),
    CHECK ((reservation_receipt IS NULL
            AND reservation_receipt_sha256 IS NULL AND reserved_at IS NULL)
        OR (jsonb_typeof(reservation_receipt)='object'
            AND reservation_receipt_sha256 IS NOT NULL
            AND reserved_at IS NOT NULL))
);

CREATE FUNCTION creative_craft_launcher_reservation_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (OLD.user_id,OLD.attempt_id,OLD.job_id,OLD.step_id,OLD.attempt_no,
        OLD.claim_lease_token,OLD.fence_epoch,OLD.admission_id,
        OLD.admission_sha256,OLD.claim_set_sha256,OLD.dispatch_id,
        OLD.request_sha256,OLD.request_authority,OLD.profile_id,
        OLD.profile_sha256,OLD.control_document,OLD.input_root,OLD.output_root,
        OLD.inputs,OLD.expected_outputs,OLD.limits,OLD.authority_sha256,
        OLD.prepared_at) IS DISTINCT FROM
       (NEW.user_id,NEW.attempt_id,NEW.job_id,NEW.step_id,NEW.attempt_no,
        NEW.claim_lease_token,NEW.fence_epoch,NEW.admission_id,
        NEW.admission_sha256,NEW.claim_set_sha256,NEW.dispatch_id,
        NEW.request_sha256,NEW.request_authority,NEW.profile_id,
        NEW.profile_sha256,NEW.control_document,NEW.input_root,NEW.output_root,
        NEW.inputs,NEW.expected_outputs,NEW.limits,NEW.authority_sha256,
        NEW.prepared_at) THEN
        RAISE EXCEPTION 'creative craft launcher authority is immutable';
    END IF;
    IF OLD.reserved_at IS NOT NULL AND OLD IS DISTINCT FROM NEW THEN
        RAISE EXCEPTION 'creative craft launcher reservation is immutable';
    END IF;
    IF OLD.reserved_at IS NULL AND NEW.reserved_at IS NULL
       AND OLD IS DISTINCT FROM NEW THEN
        RAISE EXCEPTION 'creative craft launcher reservation append is incomplete';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER creative_craft_launcher_reservation_guard
    BEFORE UPDATE ON creative_craft_launcher_reservations
    FOR EACH ROW EXECUTE FUNCTION creative_craft_launcher_reservation_guard();

CREATE TRIGGER account_write_allowed
    BEFORE INSERT OR UPDATE ON creative_craft_launcher_reservations
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();

CREATE TABLE creative_craft_launcher_ack_outbox (
    user_id uuid NOT NULL,
    source_attempt_id uuid NOT NULL,
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
    terminal_status text NOT NULL
        CHECK (terminal_status IN ('succeeded','failed','cancelled')),
    dispatch_id uuid NOT NULL,
    request_sha256 text NOT NULL
        CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
    authority_sha256 text NOT NULL
        CHECK (authority_sha256 ~ '^[0-9a-f]{64}$'),
    terminal_receipt_sha256 text NOT NULL
        CHECK (terminal_receipt_sha256 ~ '^[0-9a-f]{64}$'),
    candidate_id uuid,
    quarantine_set_sha256 text
        CHECK (quarantine_set_sha256 ~ '^[0-9a-f]{64}$'),
    adoption_attempt_id uuid,
    adoption_fence_epoch bigint CHECK (adoption_fence_epoch > 0),
    adoption_result_sha256 text
        CHECK (adoption_result_sha256 ~ '^[0-9a-f]{64}$'),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','running','done','dead')),
    lease_token uuid,
    lease_until timestamptz,
    attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    last_error text,
    available_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    PRIMARY KEY (user_id,source_attempt_id),
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
                 adoption_attempt_id,adoption_fence_epoch,adoption_result_sha256)
        REFERENCES creative_candidate_quarantines
            (user_id,candidate_id,quarantine_set_sha256,adoption_attempt_id,
             adoption_fence_epoch,adoption_result_sha256),
    CHECK ((terminal_status='succeeded') = (candidate_id IS NOT NULL)),
    CHECK ((candidate_id IS NULL) = (quarantine_set_sha256 IS NULL)),
    CHECK ((candidate_id IS NULL) = (adoption_attempt_id IS NULL)),
    CHECK ((candidate_id IS NULL) = (adoption_fence_epoch IS NULL)),
    CHECK ((candidate_id IS NULL) = (adoption_result_sha256 IS NULL)),
    CHECK ((status='running') = (lease_token IS NOT NULL)),
    CHECK ((status='running') = (lease_until IS NOT NULL)),
    CHECK ((status='done') = (completed_at IS NOT NULL))
);

CREATE INDEX creative_craft_launcher_ack_pending
    ON creative_craft_launcher_ack_outbox
       (status,available_at,lease_until,created_at)
    WHERE status IN ('pending','running');

CREATE FUNCTION creative_craft_launcher_ack_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (OLD.user_id,OLD.source_attempt_id,OLD.job_id,OLD.source_step_id,
        OLD.attempt_no,OLD.claim_lease_token,OLD.fence_epoch,
        OLD.admission_sha256,OLD.claim_set_sha256,OLD.kind,OLD.provider_call,
        OLD.terminal_status,OLD.dispatch_id,OLD.request_sha256,
        OLD.authority_sha256,OLD.terminal_receipt_sha256,OLD.candidate_id,
        OLD.quarantine_set_sha256,OLD.adoption_attempt_id,
        OLD.adoption_fence_epoch,OLD.adoption_result_sha256,OLD.created_at)
       IS DISTINCT FROM
       (NEW.user_id,NEW.source_attempt_id,NEW.job_id,NEW.source_step_id,
        NEW.attempt_no,NEW.claim_lease_token,NEW.fence_epoch,
        NEW.admission_sha256,NEW.claim_set_sha256,NEW.kind,NEW.provider_call,
        NEW.terminal_status,NEW.dispatch_id,NEW.request_sha256,
        NEW.authority_sha256,NEW.terminal_receipt_sha256,NEW.candidate_id,
        NEW.quarantine_set_sha256,NEW.adoption_attempt_id,
        NEW.adoption_fence_epoch,NEW.adoption_result_sha256,NEW.created_at) THEN
        RAISE EXCEPTION 'creative craft launcher ACK identity is immutable';
    END IF;
    IF OLD.status IN ('done','dead') AND OLD IS DISTINCT FROM NEW THEN
        RAISE EXCEPTION 'terminal creative craft launcher ACK is immutable';
    END IF;
    IF NEW.attempt_count < OLD.attempt_count THEN
        RAISE EXCEPTION 'creative craft launcher ACK attempts are monotonic';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER creative_craft_launcher_ack_guard
    BEFORE UPDATE ON creative_craft_launcher_ack_outbox
    FOR EACH ROW EXECUTE FUNCTION creative_craft_launcher_ack_guard();

CREATE TRIGGER account_write_allowed
    BEFORE INSERT OR UPDATE ON creative_craft_launcher_ack_outbox
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();
