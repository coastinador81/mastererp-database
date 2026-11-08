-- Keep the observed speech boundary with its exact persisted transcript.
-- Existing rows remain unknown: history is never backfilled into authority.
ALTER TABLE uony_live_turns
    ADD COLUMN finalized_by text NOT NULL DEFAULT ''
    CHECK (finalized_by IN ('', 'caption_recovery', 'reply_boundary',
        'model_turn_complete', 'read_only_boundary', 'primary_vad_closed',
        'provider_finished'));

-- The server stores one validated semantic proposal on the existing handoff.
-- It does not confer permission or replace action-specific access checks.
ALTER TABLE uony_live_handoffs
    ADD COLUMN semantic_decision jsonb
    CHECK (semantic_decision IS NULL OR jsonb_typeof(semantic_decision) = 'object');

ALTER TABLE uony_live_handoffs
    DROP CONSTRAINT uony_live_handoffs_intent_check;
ALTER TABLE uony_live_handoffs
    ADD CONSTRAINT uony_live_handoffs_intent_check
    CHECK (intent IN ('create_product', 'use_drive_materials', 'creative_plan',
                      'semantic_request'));
