# Productos

Objetivo específico: Gestionar identidad y ficha maestra de productos.

Responsabilidad: Productos, dentro de Catálogo.
Estado: candidato funcional no aplicado en DEV. `017_catalog_products.sql`
amplía el maestro existente e incorpora lectura, alta idempotente y edición
optimista sin mezclar tablas de Inventario.


## Contrato y estado de esta capa

Código: 2.3.4.1. Nombre/ruta: `2.3.4.1-products`. Objetivo y alcance: los descritos arriba; esta carpeta no amplía las responsabilidades de su módulo padre. Propietario funcional: dominio Ecommerce / Catálogo compartido; responsable nominal pendiente de asignación. Propietario de los datos: módulo que define sus entidades; no copiar datos de otros dominios.

Capa: datos. Dependencias: contexto autenticado, tenant y contratos del padre cuando correspondan; contratos adicionales pendientes de definición. Exclusiones: lógica y recursos de otros módulos; conectores técnicos fuera de Digital Sales. APIs/eventos/MCP: no declarar disponibles por existir esta carpeta; revisar implementación y contrato antes de consumir. Propuestas sin contrato confirmado permanecen pendientes.

Estado verificable: `catalog_products_test.sql` cubre creación/replay, edición,
versión obsoleta, filtros y ausencia de DML directo. El modelo completo pasó dos
aplicaciones en PostgreSQL 17.9 desechable.

Validaciones: `validate_administration_disposable.py` y estructura local.
Pendiente: aplicación explícita en DEV y reconciliación del futuro backfill.
