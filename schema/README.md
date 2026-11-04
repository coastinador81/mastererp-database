Modelo SQL idempotente de Plataforma, Organización, Catálogo, Administración y
Operaciones. Pedidos se incorpora en `016_operations_orders.sql`; las pruebas
rollback-only viven en `tests/operations_orders_test.sql`.
Productos se amplía en `017_catalog_products.sql`; sus pruebas rollback-only
viven en `tests/catalog_products_test.sql`.
Nodos e Inventario se incorporan en `018_operations_nodes.sql` y
`019_catalog_inventory.sql`, con prueba integrada rollback-only.
Repartidores se incorpora en `020_transport_drivers.sql`; su prueba autorizada
rollback-only vive en `tests/transport_drivers_test.sql`.
Categorías se incorpora en `021_catalog_categories.sql`; conserva slugs estables
y jerarquía, con prueba rollback-only en `tests/catalog_categories_test.sql`.
Atributos se incorpora en `022_catalog_attributes.sql`; define tipos, opciones y
alcance por categoría, con prueba en `tests/catalog_attributes_test.sql`.
Marcas y Proveedores se incorporan en `023_catalog_brands.sql` y
`024_catalog_suppliers.sql`; reutilizan Productos y Terceros canónicos.
`028_catalog_migration_lookup.sql` añade resolución autorizada y acotada de la
referencia externa de Producto para loaders e integraciones; no concede DML.
`029_administration_migration_lookup.sql` resuelve el Cliente canónico por
referencia externa y empresa autorizada; tampoco concede DML directo.
`030_operations_migration_lookup.sql` resuelve Pedidos por referencia externa
dentro de tenant y empresa para Rutas e integraciones de migración autorizadas.
`031_transport_migration_lookup.sql` resuelve Repartidores por referencia
externa bajo el permiso y alcance de Transporte.
