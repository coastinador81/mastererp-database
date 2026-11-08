-- Reconciliation reuses persisted originals; it is a durable, idempotent operation.
ALTER TABLE product_material_controls DROP CONSTRAINT product_material_controls_action_check;
ALTER TABLE product_material_controls ADD CONSTRAINT product_material_controls_action_check
    CHECK(action IN ('pause','resume','reconcile'));
