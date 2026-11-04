DO $$
DECLARE missing text[];
BEGIN
 SELECT array_agg(required.code ORDER BY required.code) INTO missing
 FROM (VALUES
  ('catalog.products.read'), ('catalog.products.write'),
  ('operations.nodes.read'), ('operations.nodes.write'),
  ('catalog.inventory.read'), ('catalog.inventory.write'), ('catalog.inventory.reserve'),
  ('transport.drivers.read'), ('transport.drivers.write'), ('transport.drivers.assign'),
  ('catalog.categories.read'), ('catalog.categories.write'),
  ('catalog.attributes.read'), ('catalog.attributes.write'),
  ('catalog.brands.read'), ('catalog.brands.write'),
  ('catalog.suppliers.read'), ('catalog.suppliers.write'),
  ('operations.preparation.read'), ('operations.preparation.write'),
  ('operations.routes.read'), ('operations.routes.write'),
  ('digital_sales.ecommerce.read'), ('digital_sales.ecommerce.write')
 ) AS required(code)
 WHERE NOT EXISTS (
  SELECT 1 FROM plataforma.role_permissions mapping
  JOIN plataforma.roles role ON role.id = mapping.role_id
  WHERE role.code = 'tenant.owner' AND mapping.permission_code = required.code
 );
 IF missing IS NOT NULL THEN
  RAISE EXCEPTION 'tenant.owner canonical permissions missing';
 END IF;
END $$;

