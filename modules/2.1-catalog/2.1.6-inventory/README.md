# Inventario

Objetivo específico: Consultar y controlar existencias; reglas de movimientos pendientes de contrato.

Responsabilidad: Inventario, dentro de Catálogo.
Estado: candidato no aplicado en DEV. `019_catalog_inventory.sql` implementa
stock por nodo, movimientos inmutables y reservas atómicas.


## Contrato y estado de esta capa

Código: 2.1.6. Nombre/ruta: `2.1.6-inventory`. Objetivo y alcance: los descritos arriba; esta carpeta no amplía las responsabilidades de su módulo padre. Propietario funcional: dominio Catálogo; responsable nominal pendiente de asignación. Propietario de los datos: módulo que define sus entidades; no copiar datos de otros dominios.

Capa: datos. Dependencias: contexto autenticado, tenant y contratos del padre cuando correspondan; contratos adicionales pendientes de definición. Exclusiones: lógica y recursos de otros módulos; conectores técnicos fuera de Digital Sales. APIs/eventos/MCP: no declarar disponibles por existir esta carpeta; revisar implementación y contrato antes de consumir. Propuestas sin contrato confirmado permanecen pendientes.

Estado verificable: PostgreSQL 17.9 desechable, migración repetible y pruebas rollback-only.

Validaciones: estructura local mediante scripts/validate_structure.py. Pendientes: contratos específicos, responsable nominal y pruebas funcionales antes de habilitar esta capacidad.
