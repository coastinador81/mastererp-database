-- Forward-only authorization repair for canonical modules introduced in 017-027.
-- The permissions already exist; this only completes the tenant.owner role map.
WITH canonical_permissions(code) AS (
 VALUES
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
)
INSERT INTO plataforma.role_permissions(role_id, permission_code)
SELECT role.id, permission.code
FROM plataforma.roles role
JOIN canonical_permissions permission ON true
JOIN plataforma.permissions declared ON declared.code = permission.code
WHERE role.code = 'tenant.owner'
ON CONFLICT DO NOTHING;

