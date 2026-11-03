# Proveedores

Responsabilidad general: Gestionar la relación administrativa de compras con los proveedores del maestro de Catálogo, sin duplicarlo.

Estado: primera capacidad de terceros implementada en DEV; ver evidencia y límites al final.

Propietario funcional: Finanzas → Administración; responsable nominal pendiente de asignación.
Dependencias: contexto autorizado de tenant y contratos del padre; reglas y criterios de aceptación se definirán con el Product Owner al priorizar la tarea.

Maestro de referencia: [Proveedores de Catálogo](../../../../2.1-catalog/2.1.5-suppliers/README.md). Esta dependencia documental no acredita que el maestro esté implementado; consumir su contrato cuando exista, sin copiar sus datos.

## Cierre funcional de esta entrega

Listar paginado, detalle, crear y actualizar se comprobaron por API Gateway con JWT y persistencia real. Funciones SQL 014 y credenciales mastererp_app; sin escritura general. El historial de diagnóstico anterior no representa el estado actual de esta capacidad. Contratos y evidencia: docs/ADMINISTRATION_PARTIES.md en cada repositorio y docs/ADMINISTRATION_PARTIES_DEV.md en Database.
