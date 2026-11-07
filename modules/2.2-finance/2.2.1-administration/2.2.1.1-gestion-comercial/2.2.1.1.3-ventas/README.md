# Ventas

Responsabilidad general: Organizar la gestión administrativa de las ventas.

Estado: persistencia y confirmación eCommerce validadas en AWS DEV; frontend y CRUD propios de Ventas pendientes.

Propietario funcional: Finanzas → Administración; responsable nominal pendiente de asignación.
Dependencias: contexto autorizado de tenant y contratos del padre; reglas y criterios de aceptación se definirán con el Product Owner al priorizar la tarea.


## Relación y comando de pedidos — DEV validado

046 y 047 aplicadas/reaplicadas por el migrador oficial. Un pedido eCommerce confirmado genera una sola venta mediante comando transaccional autorizado; rol Administradores de Finanzas sin escritura operativa general. Validación SQL efectiva y 14 casos HTTP, incluida concurrencia con commit. Ver [contrato, evidencia y pendientes](../../../../../docs/SALES_ORDER_COMMAND.md). No hay facturación/cobros automáticos ni frontend nuevo. Las ventas de fixture selladas se conservan en un tenant DEV suspendido.
