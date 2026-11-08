-- Forward-only durable compensation for Launcher V2 preparations that never
-- obtained a PostgreSQL reserve receipt.  Migration 108 is already frozen.

DROP TRIGGER creative_craft_launcher_reservation_guard
    ON creative_craft_launcher_reservations;
DROP TRIGGER account_write_allowed
    ON creative_craft_launcher_reservations;

ALTER TABLE creative_craft_launcher_reservations
    ADD COLUMN compensation_status text,
    ADD COLUMN compensation_lease_token uuid,
    ADD COLUMN compensation_lease_until timestamptz,
    ADD COLUMN compensation_attempt_count integer NOT NULL DEFAULT 0,
    ADD COLUMN compensation_last_error text,
    ADD COLUMN compensation_receipt jsonb,
    ADD COLUMN compensation_receipt_sha256 text,
    ADD COLUMN compensated_at timestamptz,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();

-- A 108 row with a reserve receipt is already confirmed.  A row without one
-- is precisely the abandoned-preparation candidate introduced by this gate.
UPDATE creative_craft_launcher_reservations
SET compensation_status=CASE
    WHEN reserved_at IS NULL THEN 'pending' ELSE 'confirmed' END;

ALTER TABLE creative_craft_launcher_reservations
    ALTER COLUMN compensation_status SET DEFAULT 'pending',
    ALTER COLUMN compensation_status SET NOT NULL,
    ADD CONSTRAINT creative_craft_launcher_compensation_status_check
        CHECK (compensation_status IN
               ('pending','running','confirmed','compensated')),
    ADD CONSTRAINT creative_craft_launcher_compensation_attempt_count_check
        CHECK (compensation_attempt_count >= 0),
    ADD CONSTRAINT creative_craft_launcher_compensation_irreversible_check
        CHECK ((compensation_status IN ('running','compensated')) =
               (compensation_attempt_count > 0)),
    ADD CONSTRAINT creative_craft_launcher_compensation_receipt_sha256_check
        CHECK (compensation_receipt_sha256 IS NULL OR
               compensation_receipt_sha256 ~ '^[0-9a-f]{64}$'),
    ADD CONSTRAINT creative_craft_launcher_compensation_running_token_check
        CHECK ((compensation_status='running') =
               (compensation_lease_token IS NOT NULL)),
    ADD CONSTRAINT creative_craft_launcher_compensation_running_until_check
        CHECK ((compensation_status='running') =
               (compensation_lease_until IS NOT NULL)),
    ADD CONSTRAINT creative_craft_launcher_compensation_confirmed_check
        CHECK ((compensation_status='confirmed') = (reserved_at IS NOT NULL)),
    ADD CONSTRAINT creative_craft_launcher_compensated_at_check
        CHECK ((compensation_status='compensated') =
               (compensated_at IS NOT NULL)),
    ADD CONSTRAINT creative_craft_launcher_compensation_receipt_check
        CHECK ((compensation_status='compensated') =
               (compensation_receipt IS NOT NULL)),
    ADD CONSTRAINT creative_craft_launcher_compensation_receipt_hash_check
        CHECK ((compensation_status='compensated') =
               (compensation_receipt_sha256 IS NOT NULL)),
    ADD CONSTRAINT creative_craft_launcher_compensation_receipt_shape_check
        CHECK (compensation_receipt IS NULL OR
               jsonb_typeof(compensation_receipt)='object');

CREATE INDEX creative_craft_launcher_compensation_pending
    ON creative_craft_launcher_reservations
       (compensation_status,compensation_lease_until,prepared_at)
    WHERE compensation_status IN ('pending','running');

CREATE OR REPLACE FUNCTION creative_craft_launcher_reservation_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
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
    IF OLD.compensation_attempt_count > NEW.compensation_attempt_count THEN
        RAISE EXCEPTION 'creative craft launcher compensation attempts are monotonic';
    END IF;
    IF OLD.reserved_at IS NOT NULL AND
       (OLD.reservation_receipt,OLD.reservation_receipt_sha256,OLD.reserved_at)
       IS DISTINCT FROM
       (NEW.reservation_receipt,NEW.reservation_receipt_sha256,NEW.reserved_at) THEN
        RAISE EXCEPTION 'creative craft launcher reserve receipt is immutable';
    END IF;
    IF OLD.compensation_status IN ('confirmed','compensated')
       AND OLD IS DISTINCT FROM NEW THEN
        RAISE EXCEPTION 'terminal creative craft launcher preparation is immutable';
    END IF;
    IF NOT (
        (OLD.compensation_status='pending'
         AND NEW.compensation_status IN ('running','confirmed')) OR
        (OLD.compensation_status='running'
         AND NEW.compensation_status IN ('running','compensated'))
    ) THEN
        RAISE EXCEPTION 'invalid creative craft launcher compensation transition';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER creative_craft_launcher_reservation_guard
    BEFORE UPDATE ON creative_craft_launcher_reservations
    FOR EACH ROW EXECUTE FUNCTION creative_craft_launcher_reservation_guard();

CREATE FUNCTION creative_craft_launcher_reservation_write_allowed()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE deleting timestamptz;
BEGIN
    SELECT deletion_requested_at INTO deleting FROM users WHERE id=NEW.user_id;
    IF deleting IS NULL THEN
        RETURN NEW;
    END IF;
    -- Account deletion may win immediately after its blocker scan while a
    -- preparation that already held the owner lock commits.  Under deletion,
    -- only the state transitions needed to remove that blocker remain legal.
    IF TG_OP='UPDATE'
       AND OLD.user_id=NEW.user_id
       AND OLD.reserved_at IS NULL AND NEW.reserved_at IS NULL
       AND ((OLD.compensation_status='pending'
             AND NEW.compensation_status='running') OR
            (OLD.compensation_status='running'
             AND NEW.compensation_status IN ('running','compensated'))) THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'Account deletion pending' USING ERRCODE='55000';
END;
$$;

CREATE TRIGGER account_write_allowed
    BEFORE INSERT OR UPDATE ON creative_craft_launcher_reservations
    FOR EACH ROW EXECUTE FUNCTION
        creative_craft_launcher_reservation_write_allowed();
