-- Register the technical evaluation policy and distinguish server-produced
-- receipts from historical caller-authored rows. No route or worker is added.
CREATE TABLE creative_evaluation_policies (
    policy_id text NOT NULL,
    policy_version text NOT NULL,
    policy_sha256 text NOT NULL CHECK (policy_sha256 ~ '^[0-9a-f]{64}$'),
    evaluator text NOT NULL,
    implementation_sha256 text NOT NULL
        CHECK (implementation_sha256 ~ '^[0-9a-f]{64}$'),
    policy jsonb NOT NULL CHECK (jsonb_typeof(policy)='object'),
    implementation jsonb NOT NULL CHECK (jsonb_typeof(implementation)='object'),
    registered_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (policy_id,policy_version),
    UNIQUE (policy_id,policy_version,policy_sha256),
    UNIQUE (policy_sha256)
);

CREATE TRIGGER creative_evaluation_policy_immutable
    BEFORE UPDATE OR DELETE ON creative_evaluation_policies
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_receipt_immutable();

CREATE TABLE creative_inspection_implementations (
    inspector text NOT NULL,
    implementation_sha256 text NOT NULL
        CHECK (implementation_sha256 ~ '^[0-9a-f]{64}$'),
    source_manifest jsonb NOT NULL CHECK (jsonb_typeof(source_manifest)='object'),
    registered_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (inspector,implementation_sha256)
);
CREATE TRIGGER creative_inspection_implementation_immutable
    BEFORE UPDATE OR DELETE ON creative_inspection_implementations
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_receipt_immutable();

CREATE TABLE creative_candidate_inspections (
    user_id uuid NOT NULL,
    id uuid NOT NULL,
    candidate_id uuid NOT NULL,
    quarantine_set_sha256 text NOT NULL
        CHECK (quarantine_set_sha256 ~ '^[0-9a-f]{64}$'),
    inspector text NOT NULL,
    implementation_sha256 text NOT NULL
        CHECK (implementation_sha256 ~ '^[0-9a-f]{64}$'),
    inspection_sha256 text NOT NULL
        CHECK (inspection_sha256 ~ '^[0-9a-f]{64}$'),
    technical_passed boolean NOT NULL,
    received_at timestamptz NOT NULL,
    receipt jsonb NOT NULL CHECK (jsonb_typeof(receipt)='object'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (user_id,id),
    UNIQUE (user_id,candidate_id,quarantine_set_sha256),
    UNIQUE (user_id,id,candidate_id,quarantine_set_sha256,inspection_sha256),
    FOREIGN KEY (user_id,candidate_id,quarantine_set_sha256)
        REFERENCES creative_candidate_quarantines
            (user_id,candidate_id,quarantine_set_sha256) ON DELETE CASCADE,
    FOREIGN KEY (inspector,implementation_sha256)
        REFERENCES creative_inspection_implementations
            (inspector,implementation_sha256),
    CHECK (receipt->>'inspectionId'=id::text),
    CHECK (receipt->>'candidateId'=candidate_id::text),
    CHECK (receipt->>'quarantineSetSha256'=quarantine_set_sha256),
    CHECK (receipt->>'inspector'=inspector),
    CHECK (receipt->>'implementationSha256'=implementation_sha256),
    CHECK (receipt->>'inspectionSha256'=inspection_sha256),
    CHECK ((receipt->>'technicalPassed')::boolean=technical_passed),
    CHECK ((receipt->>'receivedAt')::timestamptz=received_at),
    CHECK (receipt->'acceptedForUse'='false'::jsonb),
    CHECK (receipt->'publicationAuthorized'='false'::jsonb)
);
CREATE TRIGGER creative_candidate_inspection_immutable
    BEFORE UPDATE OR DELETE ON creative_candidate_inspections
    FOR EACH ROW EXECUTE FUNCTION creative_candidate_receipt_immutable();
CREATE TRIGGER account_write_allowed
    BEFORE INSERT ON creative_candidate_inspections
    FOR EACH ROW EXECUTE FUNCTION account_write_allowed();

CREATE FUNCTION creative_inspection_server_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE entry record;
DECLARE calculated_pass boolean;
BEGIN
    IF jsonb_typeof(NEW.receipt->'results') IS DISTINCT FROM 'array'
       OR jsonb_typeof(NEW.receipt->'technicalPassed') IS DISTINCT FROM 'boolean'
       OR NEW.receipt->>'schemaVersion' IS DISTINCT FROM '1'
       OR NEW.receipt->>'inspectionId' IS DISTINCT FROM NEW.id::text
       OR NEW.receipt->>'candidateId' IS DISTINCT FROM NEW.candidate_id::text
       OR NEW.receipt->>'quarantineSetSha256'
          IS DISTINCT FROM NEW.quarantine_set_sha256
       OR NEW.receipt->>'inspector' IS DISTINCT FROM NEW.inspector
       OR NEW.inspector IS DISTINCT FROM 'uonify-server-byte-inspector'
       OR NEW.receipt->>'implementationSha256'
          IS DISTINCT FROM NEW.implementation_sha256
       OR NEW.receipt->>'inspectionSha256'
          IS DISTINCT FROM NEW.inspection_sha256
       OR (NEW.receipt->>'technicalPassed')::boolean
          IS DISTINCT FROM NEW.technical_passed
       OR (NEW.receipt->>'receivedAt')::timestamptz
          IS DISTINCT FROM NEW.received_at
       OR NEW.receipt->'acceptedForUse' IS DISTINCT FROM 'false'::jsonb
       OR NEW.receipt->'publicationAuthorized' IS DISTINCT FROM 'false'::jsonb
    THEN
        RAISE EXCEPTION 'creative inspection authority does not match receipt';
    END IF;
    IF jsonb_array_length(NEW.receipt->'results') IS DISTINCT FROM (
          SELECT count(*) FROM creative_candidate_quarantine_assets
          WHERE user_id=NEW.user_id AND candidate_id=NEW.candidate_id) THEN
        RAISE EXCEPTION 'creative inspection authority does not match receipt';
    END IF;
    FOR entry IN
        SELECT value AS result,r.* FROM jsonb_array_elements(NEW.receipt->'results')
          WITH ORDINALITY inspected(value,ordinal)
        JOIN creative_candidate_quarantine_assets q
          ON q.user_id=NEW.user_id AND q.candidate_id=NEW.candidate_id
         AND q.ordinal=inspected.ordinal-1
        JOIN creative_asset_revisions r ON r.user_id=q.user_id
         AND r.asset_id=q.asset_id AND r.revision=q.revision
    LOOP
        IF jsonb_typeof(entry.result) IS DISTINCT FROM 'object'
           OR jsonb_typeof(entry.result->'issues') IS DISTINCT FROM 'array'
           OR jsonb_typeof(entry.result->'measurements') IS DISTINCT FROM 'object'
           OR jsonb_typeof(entry.result->'automaticPassed')
              IS DISTINCT FROM 'boolean'
           OR entry.result->>'assetId' IS DISTINCT FROM entry.asset_id::text
           OR (entry.result->>'revision')::integer IS DISTINCT FROM entry.revision
           OR entry.result->>'snapshotSha256'
              IS DISTINCT FROM entry.snapshot_sha256
           OR (entry.result->'measurements'->>'observedByteSize')::bigint
              IS DISTINCT FROM entry.byte_size
           OR entry.result->'measurements'->>'observedSha256'
              IS DISTINCT FROM entry.sha256
           OR entry.result->'measurements'->>'mimeType'
              IS DISTINCT FROM entry.mime_type
           OR entry.result->'measurements'->>'kind' IS DISTINCT FROM entry.kind
           OR (entry.result->'measurements'->>'storageGeneration')::bigint
              IS DISTINCT FROM entry.storage_generation
           OR (entry.result->>'automaticPassed')::boolean
              IS DISTINCT FROM (jsonb_array_length(entry.result->'issues')=0)
           OR (entry.result->>'automaticPassed')::boolean AND NOT COALESCE((
              (entry.kind='image' AND entry.mime_type='image/png'
               AND entry.result->'measurements'->'decoded'->>'decoder'
                   ='uonify.strict-png-v1'
               AND (entry.result->'measurements'->'decoded'->>'widthPixels')::integer
                   =(entry.media->>'widthPixels')::integer
               AND (entry.result->'measurements'->'decoded'->>'heightPixels')::integer
                   =(entry.media->>'heightPixels')::integer)
              OR
              (entry.kind='image_sequence'
               AND entry.mime_type='application/zip'
               AND entry.result->'measurements'->'decoded'->>'decoder'
                   ='uonify.strict-png-sequence-v1'
               AND (entry.result->'measurements'->'decoded'->>'decodedFrames')::integer
                   =(entry.media->>'frameCount')::integer
               AND entry.result->'measurements'->'decoded'->>'manifestSha256'
                   =entry.media->>'manifestSha256')),false)
           OR NOT (entry.result->>'automaticPassed')::boolean AND NOT (
              entry.result->'issues'='["technical_decode_failed"]'::jsonb
              OR entry.result->'issues'='["technical_decoder_not_implemented"]'::jsonb)
        THEN
            RAISE EXCEPTION 'creative inspection result is not server-derived';
        END IF;
    END LOOP;
    SELECT COALESCE(bool_and((item->>'automaticPassed')::boolean),false)
      INTO calculated_pass FROM jsonb_array_elements(NEW.receipt->'results') item;
    IF calculated_pass IS DISTINCT FROM NEW.technical_passed THEN
        RAISE EXCEPTION 'creative inspection aggregate does not match results';
    END IF;
    RETURN NEW;
END; $$;
CREATE TRIGGER creative_inspection_server_guard
    BEFORE INSERT ON creative_candidate_inspections
    FOR EACH ROW EXECUTE FUNCTION creative_inspection_server_guard();

ALTER TABLE creative_candidate_receipts
    ADD COLUMN receipt_authority text NOT NULL DEFAULT 'legacy_caller'
        CHECK (receipt_authority IN ('legacy_caller','server_clock')),
    ADD CONSTRAINT creative_candidate_received_at_matches_receipt
        CHECK (receipt ? 'receivedAt'
            AND received_at=(receipt->>'receivedAt')::timestamptz);

ALTER TABLE creative_candidate_evaluations
    ADD COLUMN authority text NOT NULL DEFAULT 'legacy_caller'
        CHECK (authority IN ('legacy_caller','server_registered')),
    ADD COLUMN policy_id text,
    ADD COLUMN policy_version text,
    ADD COLUMN implementation_sha256 text
        CHECK (implementation_sha256 IS NULL
            OR implementation_sha256 ~ '^[0-9a-f]{64}$'),
    ADD COLUMN inspection_id uuid,
    ADD COLUMN inspection_sha256 text
        CHECK (inspection_sha256 IS NULL
            OR inspection_sha256 ~ '^[0-9a-f]{64}$'),
    ADD COLUMN received_at timestamptz,
    ADD CONSTRAINT creative_evaluation_registered_policy
        FOREIGN KEY (policy_id,policy_version,policy_sha256)
        REFERENCES creative_evaluation_policies
            (policy_id,policy_version,policy_sha256),
    ADD CONSTRAINT creative_evaluation_registered_inspection
        FOREIGN KEY (user_id,inspection_id,candidate_id,
                     quarantine_set_sha256,inspection_sha256)
        REFERENCES creative_candidate_inspections
            (user_id,id,candidate_id,quarantine_set_sha256,inspection_sha256),
    ADD CONSTRAINT creative_evaluation_authority_shape CHECK (
        (authority='legacy_caller' AND policy_id IS NULL
            AND policy_version IS NULL AND implementation_sha256 IS NULL
            AND inspection_id IS NULL AND inspection_sha256 IS NULL
            AND received_at IS NULL)
        OR
        (authority='server_registered' AND policy_id IS NOT NULL
            AND policy_version IS NOT NULL AND implementation_sha256 IS NOT NULL
            AND inspection_id IS NOT NULL AND inspection_sha256 IS NOT NULL
            AND received_at IS NOT NULL
            AND receipt->>'policyId'=policy_id
            AND receipt->>'policyVersion'=policy_version
            AND receipt->>'policySha256'=policy_sha256
            AND receipt->>'implementationSha256'=implementation_sha256
            AND receipt->>'inspectionId'=inspection_id::text
            AND receipt->>'inspectionSha256'=inspection_sha256
            AND (receipt->>'receivedAt')::timestamptz=received_at));

CREATE FUNCTION creative_structural_issues(
    kind_value text,mime_value text,byte_value bigint,generation_value bigint,
    sha_value text,media_value jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE issues jsonb := '[]'::jsonb;
DECLARE rate jsonb := media_value->'frameRate';
BEGIN
    IF kind_value NOT IN ('image','video','audio','image_sequence') THEN
        issues := issues || '["unsupported_kind"]'::jsonb;
    END IF;
    IF NOT ((kind_value='image' AND mime_value LIKE 'image/%')
        OR (kind_value='video' AND mime_value LIKE 'video/%')
        OR (kind_value='audio' AND mime_value LIKE 'audio/%')
        OR (kind_value='image_sequence' AND mime_value='application/zip')) THEN
        issues := issues || '["mime_kind_mismatch"]'::jsonb;
    END IF;
    IF byte_value < 1 THEN issues := issues || '["invalid_byte_size"]'::jsonb; END IF;
    IF generation_value < 1 THEN
        issues := issues || '["invalid_storage_generation"]'::jsonb;
    END IF;
    IF sha_value !~ '^[0-9a-f]{64}$' THEN
        issues := issues || '["invalid_asset_sha256"]'::jsonb;
    END IF;
    IF kind_value IN ('image','video','image_sequence') AND NOT COALESCE((
        jsonb_typeof(media_value->'widthPixels')='number'
        AND (media_value->>'widthPixels')::numeric>0
        AND jsonb_typeof(media_value->'heightPixels')='number'
        AND (media_value->>'heightPixels')::numeric>0),false) THEN
        issues := issues || '["invalid_visual_geometry"]'::jsonb;
    END IF;
    IF kind_value IN ('video','image_sequence') AND NOT COALESCE((
        jsonb_typeof(media_value->'durationSeconds')='number'
        AND (media_value->>'durationSeconds')::numeric>0
        AND jsonb_typeof(rate)='object'
        AND (rate->>'numerator')::numeric>0
        AND (rate->>'denominator')::numeric>0),false) THEN
        issues := issues || '["invalid_timed_media"]'::jsonb;
    END IF;
    IF kind_value='image_sequence' AND NOT COALESCE((
        (media_value->>'frameCount')::integer>0
        AND media_value->>'manifestSha256' ~ '^[0-9a-f]{64}$'
        AND media_value->>'bundlePlanSha256' ~ '^[0-9a-f]{64}$'
        AND media_value->>'format'='uonify.effect-frame-bundle.v1'),false) THEN
        issues := issues || '["invalid_image_sequence_manifest"]'::jsonb;
    END IF;
    IF kind_value='audio' AND NOT COALESCE((
        (media_value->>'durationSeconds')::numeric>0
        AND (media_value->>'sampleRateHz')::integer>0
        AND (media_value->>'channels')::integer>0
        AND length(media_value->>'encoding')>0),false) THEN
        issues := issues || '["incomplete_audio_metadata"]'::jsonb;
    END IF;
    RETURN COALESCE(issues,'[]'::jsonb);
END; $$;

CREATE FUNCTION creative_evaluation_server_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE registered creative_evaluation_policies%ROWTYPE;
DECLARE inspected creative_candidate_inspections%ROWTYPE;
DECLARE calculated_pass boolean;
DECLARE entry record;
DECLARE structural jsonb;
DECLARE expected_issues jsonb;
DECLARE expected_measurements jsonb;
BEGIN
    IF jsonb_typeof(NEW.receipt->'results') IS DISTINCT FROM 'array'
       OR jsonb_typeof(NEW.receipt->'automaticPassed')
          IS DISTINCT FROM 'boolean'
       OR jsonb_typeof(NEW.receipt->'readyForHumanReview')
          IS DISTINCT FROM 'boolean'
       OR NEW.receipt->>'schemaVersion' IS DISTINCT FROM '2' THEN
        RAISE EXCEPTION 'creative evaluation authority does not match receipt';
    END IF;
    IF NEW.authority <> 'server_registered' THEN
        RAISE EXCEPTION 'new creative evaluations require server authority';
    END IF;
    SELECT * INTO registered FROM creative_evaluation_policies
      WHERE policy_id=NEW.policy_id AND policy_version=NEW.policy_version
        AND policy_sha256=NEW.policy_sha256;
    SELECT * INTO inspected FROM creative_candidate_inspections
      WHERE user_id=NEW.user_id AND id=NEW.inspection_id
        AND candidate_id=NEW.candidate_id
        AND quarantine_set_sha256=NEW.quarantine_set_sha256
        AND inspection_sha256=NEW.inspection_sha256;
    IF jsonb_array_length(NEW.receipt->'results')
       <> jsonb_array_length(inspected.receipt->'results') THEN
        RAISE EXCEPTION 'creative evaluation results do not cover inspection';
    END IF;
    FOR entry IN
        SELECT evaluated.value AS evaluated_item,
            technical.value AS inspected_item,r.*
        FROM jsonb_array_elements(NEW.receipt->'results')
          WITH ORDINALITY evaluated(value,ordinal)
        JOIN jsonb_array_elements(inspected.receipt->'results')
          WITH ORDINALITY technical(value,ordinal)
          ON technical.ordinal=evaluated.ordinal
        JOIN creative_candidate_quarantine_assets q
          ON q.user_id=NEW.user_id AND q.candidate_id=NEW.candidate_id
         AND q.ordinal=evaluated.ordinal-1
        JOIN creative_asset_revisions r ON r.user_id=q.user_id
         AND r.asset_id=q.asset_id AND r.revision=q.revision
    LOOP
        structural := creative_structural_issues(
            entry.kind,entry.mime_type,entry.byte_size,
            entry.storage_generation,entry.sha256,entry.media);
        expected_issues := COALESCE(structural,'[]'::jsonb)
            || COALESCE(entry.inspected_item->'issues','[]'::jsonb);
        expected_measurements := jsonb_build_object(
            'structural',jsonb_build_object(
                'kind',entry.kind,'mimeType',entry.mime_type,
                'byteSize',entry.byte_size,'sha256',entry.sha256,
                'storageGeneration',entry.storage_generation,
                'widthPixels',entry.media->'widthPixels',
                'heightPixels',entry.media->'heightPixels',
                'durationSeconds',entry.media->'durationSeconds',
                'frameRate',entry.media->'frameRate',
                'frameCount',entry.media->'frameCount',
                'sampleRateHz',entry.media->'sampleRateHz',
                'channels',entry.media->'channels',
                'samplesPerChannel',entry.media->'samplesPerChannel',
                'encoding',entry.media->'encoding',
                'hasAlpha',entry.media->'hasAlpha',
                'manifestSha256',entry.media->'manifestSha256',
                'bundlePlanSha256',entry.media->'bundlePlanSha256',
                'format',entry.media->'format'),
            'technical',entry.inspected_item->'measurements');
        IF jsonb_typeof(entry.evaluated_item) IS DISTINCT FROM 'object'
           OR jsonb_typeof(entry.evaluated_item->'issues')
              IS DISTINCT FROM 'array'
           OR jsonb_typeof(entry.evaluated_item->'measurements')
              IS DISTINCT FROM 'object'
           OR jsonb_typeof(entry.evaluated_item->'automaticPassed')
              IS DISTINCT FROM 'boolean'
           OR entry.evaluated_item->>'assetId'
              IS DISTINCT FROM entry.inspected_item->>'assetId'
           OR entry.evaluated_item->>'revision'
              IS DISTINCT FROM entry.inspected_item->>'revision'
           OR entry.evaluated_item->>'snapshotSha256'
              IS DISTINCT FROM entry.inspected_item->>'snapshotSha256'
           OR entry.evaluated_item->'issues' IS DISTINCT FROM expected_issues
           OR entry.evaluated_item->'measurements'
              IS DISTINCT FROM expected_measurements
           OR (entry.evaluated_item->>'automaticPassed')::boolean
              IS DISTINCT FROM (jsonb_array_length(expected_issues)=0) THEN
            RAISE EXCEPTION 'creative evaluation result is not canonical'
                USING DETAIL = jsonb_build_object(
                    'actualIssues',entry.evaluated_item->'issues',
                    'expectedIssues',expected_issues,
                    'actualMeasurements',entry.evaluated_item->'measurements',
                    'expectedMeasurements',expected_measurements)::text;
        END IF;
    END LOOP;
    SELECT COALESCE(bool_and((item->>'automaticPassed')::boolean),false)
      INTO calculated_pass FROM jsonb_array_elements(NEW.receipt->'results') item;
    IF registered.policy_id IS NULL OR inspected.id IS NULL
       OR NEW.evaluator IS DISTINCT FROM registered.evaluator
       OR NEW.implementation_sha256
          IS DISTINCT FROM registered.implementation_sha256
       OR NEW.receipt->>'evaluationId' IS DISTINCT FROM NEW.id::text
       OR NEW.receipt->>'candidateId' IS DISTINCT FROM NEW.candidate_id::text
       OR NEW.receipt->>'quarantineSetSha256'
          IS DISTINCT FROM NEW.quarantine_set_sha256
       OR NEW.receipt->>'evaluator' IS DISTINCT FROM NEW.evaluator
       OR NEW.receipt->>'policyId' IS DISTINCT FROM NEW.policy_id
       OR NEW.receipt->>'policyVersion' IS DISTINCT FROM NEW.policy_version
       OR NEW.receipt->>'policySha256' IS DISTINCT FROM NEW.policy_sha256
       OR NEW.receipt->>'implementationSha256'
          IS DISTINCT FROM NEW.implementation_sha256
       OR NEW.receipt->>'inspectionId' IS DISTINCT FROM NEW.inspection_id::text
       OR NEW.receipt->>'inspectionSha256'
          IS DISTINCT FROM NEW.inspection_sha256
       OR NEW.receipt->>'inspectionImplementationSha256'
          IS DISTINCT FROM inspected.implementation_sha256
       OR NEW.receipt->>'evaluationSha256'
          IS DISTINCT FROM NEW.evaluation_sha256
       OR (NEW.receipt->>'automaticPassed')::boolean
          IS DISTINCT FROM NEW.automatic_passed
       OR (NEW.receipt->>'readyForHumanReview')::boolean
          IS DISTINCT FROM NEW.ready_for_human_review
       OR NEW.automatic_passed IS DISTINCT FROM calculated_pass
       OR NEW.ready_for_human_review IS DISTINCT FROM NEW.automatic_passed
       OR NEW.receipt->'acceptedForUse' IS DISTINCT FROM 'false'::jsonb
       OR NEW.receipt->'publicationAuthorized' IS DISTINCT FROM 'false'::jsonb
       OR (NEW.receipt->>'receivedAt')::timestamptz
          IS DISTINCT FROM NEW.received_at THEN
        RAISE EXCEPTION 'creative evaluation authority does not match receipt';
    END IF;
    RETURN NEW;
END; $$;

CREATE TRIGGER creative_evaluation_server_guard
    BEFORE INSERT ON creative_candidate_evaluations
    FOR EACH ROW EXECUTE FUNCTION creative_evaluation_server_guard();
