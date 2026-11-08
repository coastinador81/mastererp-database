-- La voz puede transferir un encargo creativo al planificador conversacional.
-- El traspaso no genera medios ni autoriza gasto.
ALTER TABLE uony_live_handoffs
    DROP CONSTRAINT uony_live_handoffs_intent_check;

ALTER TABLE uony_live_handoffs
    ADD CONSTRAINT uony_live_handoffs_intent_check
    CHECK (intent IN ('create_product', 'use_drive_materials', 'creative_plan'));
