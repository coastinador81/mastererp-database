-- Extend persisted inspection authority only for codecs that perform a real,
-- bounded decode in the server inspector. MP4 and MP3 remain fail-closed.

CREATE FUNCTION creative_inspection_decoded_matches(
    kind_value text,mime_value text,media_value jsonb,decoded_value jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT SET search_path=pg_catalog AS $$
DECLARE decoder text := decoded_value->>'decoder';
DECLARE sample_rate numeric;
DECLARE duration_delta numeric;
BEGIN
    IF jsonb_typeof(media_value) IS DISTINCT FROM 'object'
       OR jsonb_typeof(decoded_value) IS DISTINCT FROM 'object' THEN
        RETURN false;
    END IF;
    IF kind_value='image' AND mime_value IN
            ('image/png','image/jpeg','image/webp') THEN
        IF decoder IS DISTINCT FROM (CASE mime_value
                WHEN 'image/png' THEN 'uonify.strict-png-v1'
                WHEN 'image/jpeg' THEN 'uonify.pillow-jpeg-decode-v1'
                ELSE 'uonify.pillow-webp-decode-v1' END)
           OR NOT (decoded_value ?& ARRAY[
                'decoder','widthPixels','heightPixels','hasAlpha'])
           OR decoded_value - ARRAY[
                'decoder','widthPixels','heightPixels','hasAlpha']
                <> '{}'::jsonb
           OR (decoded_value->>'widthPixels')::integer
                IS DISTINCT FROM (media_value->>'widthPixels')::integer
           OR (decoded_value->>'heightPixels')::integer
                IS DISTINCT FROM (media_value->>'heightPixels')::integer
           OR (decoded_value->>'widthPixels')::integer <= 0
           OR (decoded_value->>'heightPixels')::integer <= 0
           OR (decoded_value->>'widthPixels')::bigint
                *(decoded_value->>'heightPixels')::bigint > 25000000
           OR (decoded_value->>'hasAlpha')::boolean
                IS DISTINCT FROM COALESCE(
                    (media_value->>'hasAlpha')::boolean,false) THEN
            RETURN false;
        END IF;
        RETURN true;
    END IF;
    IF kind_value='image_sequence' AND mime_value='application/zip' THEN
        RETURN decoder='uonify.strict-png-sequence-v1'
           AND decoded_value ?& ARRAY[
                'decoder','decodedFrames','unpackedBytes','widthPixels',
                'heightPixels','frameCount',
                'frameRate','durationSeconds','manifestSha256',
                'bundlePlanSha256','hasAlpha']
           AND decoded_value - ARRAY[
                'decoder','decodedFrames','unpackedBytes','widthPixels',
                'heightPixels','frameCount','frameRate','durationSeconds',
                'manifestSha256','bundlePlanSha256','hasAlpha']
                = '{}'::jsonb
           AND (decoded_value->>'decodedFrames')::integer
                =(media_value->>'frameCount')::integer
           AND (decoded_value->>'decodedFrames')::integer > 0
           AND (decoded_value->>'unpackedBytes')::bigint > 0
           AND (decoded_value->>'widthPixels')::integer
                =(media_value->>'widthPixels')::integer
           AND (decoded_value->>'heightPixels')::integer
                =(media_value->>'heightPixels')::integer
           AND (decoded_value->>'widthPixels')::integer > 0
           AND (decoded_value->>'heightPixels')::integer > 0
           AND (decoded_value->>'widthPixels')::bigint
                *(decoded_value->>'heightPixels')::bigint <= 25000000
           AND (decoded_value->>'frameCount')::integer
                =(media_value->>'frameCount')::integer
           AND (decoded_value->>'widthPixels')::bigint
                *(decoded_value->>'heightPixels')::bigint
                *(decoded_value->>'frameCount')::bigint <= 100000000
           AND decoded_value->'frameRate'=media_value->'frameRate'
           AND (decoded_value->>'durationSeconds')::numeric
                =(media_value->>'durationSeconds')::numeric
           AND decoded_value->>'manifestSha256'
                =media_value->>'manifestSha256'
           AND decoded_value->>'bundlePlanSha256'
                =media_value->>'bundlePlanSha256'
           AND (decoded_value->>'hasAlpha')::boolean IS NOT DISTINCT FROM
                COALESCE((media_value->>'hasAlpha')::boolean,false);
    END IF;
    IF kind_value='audio' AND mime_value IN
            ('audio/wav','audio/L16;codec=pcm;rate=24000') THEN
        IF decoder IS DISTINCT FROM (CASE mime_value
                WHEN 'audio/wav' THEN 'uonify.strict-wave-pcm-v1'
                ELSE 'uonify.strict-pcm-l16-v1' END)
           OR NOT (decoded_value ?& ARRAY[
                'sampleRateHz','channels','samplesPerChannel',
                'sampleWidthBytes','durationSeconds','encoding'])
           OR decoded_value - ARRAY[
                'decoder','sampleRateHz','channels','samplesPerChannel',
                'sampleWidthBytes','durationSeconds','encoding']
                <> '{}'::jsonb
           OR (decoded_value->>'sampleRateHz')::integer
                IS DISTINCT FROM (media_value->>'sampleRateHz')::integer
           OR (decoded_value->>'channels')::integer
                IS DISTINCT FROM (media_value->>'channels')::integer
           OR decoded_value->>'encoding' IS DISTINCT FROM
                (CASE mime_value WHEN 'audio/wav' THEN 'pcm_wav'
                     ELSE 'pcm_l16' END)
           OR decoded_value->>'encoding'
                IS DISTINCT FROM media_value->>'encoding'
           OR (media_value->>'samplesPerChannel') IS NOT NULL
              AND (decoded_value->>'samplesPerChannel')::bigint
                IS DISTINCT FROM
                    (media_value->>'samplesPerChannel')::bigint
           OR (decoded_value->>'samplesPerChannel')::bigint <= 0
           OR (decoded_value->>'sampleWidthBytes')::integer
                NOT BETWEEN 1 AND 4
           OR mime_value='audio/L16;codec=pcm;rate=24000'
              AND (decoded_value->>'sampleWidthBytes')::integer <> 2 THEN
            RETURN false;
        END IF;
        sample_rate := (decoded_value->>'sampleRateHz')::numeric;
        IF sample_rate <= 0 THEN RETURN false; END IF;
        duration_delta := abs(
            (decoded_value->>'durationSeconds')::numeric
            -(media_value->>'durationSeconds')::numeric);
        RETURN duration_delta <= 1/sample_rate;
    END IF;
    RETURN false;
EXCEPTION WHEN OTHERS THEN
    RETURN false;
END; $$;

REVOKE ALL ON FUNCTION creative_inspection_decoded_matches(
    text,text,jsonb,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION creative_inspection_decoded_matches(
    text,text,jsonb,jsonb) TO uonify_creative_inspector;

CREATE OR REPLACE FUNCTION creative_inspection_server_guard() RETURNS trigger
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
           OR (entry.result->>'automaticPassed')::boolean AND NOT COALESCE(
                creative_inspection_decoded_matches(
                    entry.kind,entry.mime_type,entry.media,
                    entry.result->'measurements'->'decoded'),false)
           OR NOT (entry.result->>'automaticPassed')::boolean AND NOT (
              entry.result->'issues'='["technical_decode_failed"]'::jsonb
              OR entry.result->'issues'
                 ='["technical_decoder_not_implemented"]'::jsonb)
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
