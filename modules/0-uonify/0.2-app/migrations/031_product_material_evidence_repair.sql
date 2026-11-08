-- A directed repair retains prior calls and marks their incomplete interpretation as superseded.
ALTER TABLE product_material_controls DROP CONSTRAINT product_material_controls_action_check;
ALTER TABLE product_material_controls ADD CONSTRAINT product_material_controls_action_check
    CHECK(action IN ('pause','resume','reconcile','upgrade_readers','repair_evidence'));
