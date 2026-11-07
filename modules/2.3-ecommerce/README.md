# Operations data

> Numeración vigente: consultar docs/MODULE_RENUMBERING.md desde la raíz. Las ubicaciones fuente cambian; los contratos SQL/API y stacks efectivos se conservan. Los apartados históricos no alteran la distribución nueva.


Objetivo específico: Coordinar pedidos, preparación, rutas y nodos.

Responsabilidad: pedidos, preparación, rutas y nodos. Estado: planned.

## Contrato y estado de esta capa

Código: 2.3. Nombre/ruta: `2.3-ecommerce`. Objetivo y alcance: los descritos arriba; esta carpeta no amplía las responsabilidades de su módulo padre. Propietario funcional: dominio Ecommerce; responsable nominal pendiente de asignación. Propietario de los datos: módulo que define sus entidades; no copiar datos de otros dominios.

Capa: datos. Dependencias: contexto autenticado, tenant y contratos del padre cuando correspondan; contratos adicionales pendientes de definición. Exclusiones: lógica y recursos de otros módulos; conectores técnicos fuera de Digital Sales. APIs/eventos/MCP: no declarar disponibles por existir esta carpeta; revisar implementación y contrato antes de consumir. Propuestas sin contrato confirmado permanecen pendientes.

Estado verificable: la reserva documental no acredita implementación; conservar cualquier código/plantilla existente y revisar evidencia específica antes de marcar implementado.

Validaciones: estructura local mediante scripts/validate_structure.py. Pendientes: contratos específicos, responsable nominal y pruebas funcionales antes de habilitar esta capacidad.
