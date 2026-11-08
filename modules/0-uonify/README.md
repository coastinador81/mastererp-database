# Uonify

Objetivo específico: Canal conversacional y de voz para consultar y coordinar operaciones con los módulos propietarios.

Responsabilidad: Chat, voz, memoria, conversaciones, selección de modelos, guardas y orquestación. Cerebro principal compartido.
Estado: estructura funcional; implementación pendiente.


## Contrato y estado de esta capa

Código: 0. Nombre/ruta: `0-uonify`. Objetivo y alcance: los descritos arriba; esta carpeta no amplía las responsabilidades de su módulo padre. Propietario funcional: dominio Uonify; responsable nominal pendiente de asignación. Propietario de los datos: módulo que define sus entidades; no copiar datos de otros dominios.

Capa: datos. Dependencias: contexto autenticado, tenant y contratos del padre cuando correspondan; contratos adicionales pendientes de definición. Exclusiones: lógica y recursos de otros módulos; conectores técnicos fuera de Digital Sales. APIs/eventos/MCP: no declarar disponibles por existir esta carpeta; revisar implementación y contrato antes de consumir. Propuestas sin contrato confirmado permanecen pendientes.

Estado verificable: la reserva documental no acredita implementación; conservar cualquier código/plantilla existente y revisar evidencia específica antes de marcar implementado.

Validaciones: estructura local mediante scripts/validate_structure.py. Pendientes: contratos específicos, responsable nominal y pruebas funcionales antes de habilitar esta capacidad.

## Diseño de Uonify (canon)

Todo lo visual de Uonify se rige por el [manual de identidad corporativa](https://github.com/eticayservicios/mastererp-platform/blob/dev/frontend/modules/0-uonify/identidad-corporativa/Uonify_Identidad_Corporativa.pdf). Antes de tocar diseño o UX/UI se lee el manual. No se inventan diseños ni patrones nuevos, y lo que el manual no cubra lo decide el Product Owner. La regla completa está en el README raíz del repo.
