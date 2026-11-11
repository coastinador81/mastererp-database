# Pedidos

Objetivo específico: Gestionar pedidos y sus transiciones autorizadas.

Responsabilidad: Pedidos, dentro de Ecommerce.
Estado: modelo funcional aplicado en DEV. `schema/016_operations_orders.sql`
incluye modelo multi-tenant, líneas, historial, lectura, creación idempotente y
transiciones autorizadas. La creación exige la referencia opaca de una reserva
ya emitida por el propietario de Inventario; Pedidos no escribe su stock.
`052_operations_order_history_read.sql` amplía la proyección autorizada con el
historial existente de eventos, incluido actor y fecha, sin duplicar datos.
`053_operations_order_cancellation_notes.sql` aporta notas persistentes y
cancelación coordinada. `057_operations_orders_search.sql` añade el directorio
filtrado y paginado por cursor con aislamiento de tenant y empresa.


## Contrato y estado de esta capa

Código: 2.3.1. Nombre/ruta: `2.3.1-orders`. Objetivo y alcance: los descritos arriba; esta carpeta no amplía las responsabilidades de su módulo padre. Propietario funcional: dominio Ecommerce; responsable nominal pendiente de asignación. Propietario de los datos: módulo que define sus entidades; no copiar datos de otros dominios.

Capa: datos. Dependencias: contexto autenticado, tenant y contratos del padre cuando correspondan; contratos adicionales pendientes de definición. Exclusiones: lógica y recursos de otros módulos; conectores técnicos fuera de Digital Sales. APIs/eventos/MCP: no declarar disponibles por existir esta carpeta; revisar implementación y contrato antes de consumir. Propuestas sin contrato confirmado permanecen pendientes.

Estado verificable: `tests/operations_orders_test.sql` comprueba lectura,
creación/replay idempotente, transición, búsqueda filtrada, concurrencia
optimista y ausencia de DML directo para `mastererp_app`. El modelo completo se aplicó dos veces y la
batería SQL pasó en PostgreSQL 17.9 desechable, sin red ni puertos. No acredita
aplicación en DEV.

Validaciones: `scripts/validate_administration_disposable.py` y estructura
local mediante `scripts/validate_structure.py`. Los cambios nuevos requieren
workflow oficial y smoke test DEV explícitamente autorizados.
