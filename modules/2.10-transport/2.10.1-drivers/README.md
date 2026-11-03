# Repartidores

Objetivo específico: Mantener repartidores y su disponibilidad autorizada.

Responsabilidad: Repartidores, dentro de Transporte.
Estado: candidato SQL implementado, no aplicado en DEV.


## Contrato y estado de esta capa

Código: 2.10.1. Nombre/ruta: `2.10.1-drivers`. Objetivo y alcance: los descritos arriba; esta carpeta no amplía las responsabilidades de su módulo padre. Propietario funcional: dominio Transporte; responsable nominal pendiente de asignación. Propietario de los datos: módulo que define sus entidades; no copiar datos de otros dominios.

Capa: datos. Dependencias: contexto autenticado, tenant y contratos del padre cuando correspondan; contratos adicionales pendientes de definición. Exclusiones: lógica y recursos de otros módulos; conectores técnicos fuera de Digital Sales. APIs/eventos/MCP: no declarar disponibles por existir esta carpeta; revisar implementación y contrato antes de consumir. Propuestas sin contrato confirmado permanecen pendientes.

Estado verificable: `020_transport_drivers.sql` posee perfiles multi-tenant, vínculo opcional a usuario interno, disponibilidad, estado de acceso, asignaciones a nodos, funciones autorizadas, auditoría e idempotencia. Rutas activas pertenecen a Rutas, no a Repartidores.

Validaciones: aplicación doble y fixture rollback-only como `mastererp_app`. Pendientes: promoción explícita a DEV y conciliación de datos heredados.
