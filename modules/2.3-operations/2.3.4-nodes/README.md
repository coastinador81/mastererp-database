# Nodos

Objetivo específico: Gestionar nodos de operación y su contexto.

Responsabilidad: Nodos, dentro de Operaciones.
Estado: candidato no aplicado en DEV. `018_operations_nodes.sql` modela el
perfil operativo 1:1 sobre una sucursal existente.


## Contrato y estado de esta capa

Código: 2.3.4. Nombre/ruta: `2.3.4-nodes`. Objetivo y alcance: los descritos arriba; esta carpeta no amplía las responsabilidades de su módulo padre. Propietario funcional: dominio Operaciones; responsable nominal pendiente de asignación. Propietario de los datos: módulo que define sus entidades; no copiar datos de otros dominios.

Capa: datos. Dependencias: contexto autenticado, tenant y contratos del padre cuando correspondan; contratos adicionales pendientes de definición. Exclusiones: lógica y recursos de otros módulos; conectores técnicos fuera de Digital Sales. APIs/eventos/MCP: no declarar disponibles por existir esta carpeta; revisar implementación y contrato antes de consumir. Propuestas sin contrato confirmado permanecen pendientes.

Estado verificable: PostgreSQL 17.9 desechable, migración repetible y pruebas rollback-only.

Validaciones: estructura local mediante scripts/validate_structure.py. Pendientes: contratos específicos, responsable nominal y pruebas funcionales antes de habilitar esta capacidad.
