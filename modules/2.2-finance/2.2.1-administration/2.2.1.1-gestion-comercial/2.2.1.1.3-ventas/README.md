# Ventas

Responsabilidad general: Organizar la gestión administrativa de las ventas.

Estado: pendiente de implementación.

Propietario funcional: Finanzas → Administración; responsable nominal pendiente de asignación.
Dependencias: contexto autorizado de tenant y contratos del padre; reglas y criterios de aceptación se definirán con el Product Owner al priorizar la tarea.


## Relación y comando de pedidos — candidato local

La migración 046 reutiliza documentos y detalles de Administración: un pedido confirmado genera una venta, inicialmente desde eCommerce. Incluye registro transaccional, idempotencia y anulación básica sin borrar historial. Ver [contrato, restricciones y validación pendiente](../../../../../docs/SALES_ORDER_COMMAND.md). No aplicado a RDS, sin API funcional de Ventas todavía. Las pruebas PostgreSQL y la integración con el endpoint de confirmación siguen pendientes.
