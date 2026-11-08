-- Canonical EffectCraft bundles are durable reviewable assets, but remain
-- ineligible for Craft input until a bounded image-sequence unpacker exists.
ALTER TABLE creative_asset_revisions
    DROP CONSTRAINT creative_asset_revisions_kind_check;
ALTER TABLE creative_asset_revisions
    ADD CONSTRAINT creative_asset_revisions_kind_check CHECK (
        kind IN ('image','video','audio','image_sequence'));
