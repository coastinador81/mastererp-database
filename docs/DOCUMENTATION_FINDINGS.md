# Hallazgos y decisiones abiertas

## Problemas previos, no corregidos como código en esta tarea

- Infrastructure: plantillas reorganizadas aún no equivalentes a los stacks AWS. Faltan revisión de rutas, JWT/CORS, permisos y migración de propiedad del Admin API. No desplegar como reemplazo directo.
- Platform: frontend/app-shell sigue reservado; el prototipo uonify-front es otro repositorio y no acredita implementación en MasterERP. El código histórico backend/platform-base/db-migrator no es la Lambda oficial de database. Conservarlo hasta una decisión explícita de retirada.
- Backend: existen handlers históricos de funciones eliminadas; código versionado no implica despliegue autorizado ni funcionalidad validada. Revisar su consolidación en una tarea funcional independiente.
- Autorización SQL: validada realmente en RDS DEV en 454fec7; no es un defecto pendiente ni una prueba end-to-end de APIs/backend.

## Decisiones del propietario pendientes

Asignar responsables nominales por dominio; completar contratos de APIs/eventos/MCP y límites específicos de Opsphere, MasterPay, RFID y procesos por país. Determinar plan aprobado de migración de stacks e integraciones antes de desplegar. Definir autenticación/tenant frontend antes de habilitar módulos.

## Límite de esta entrega

Solo Markdown. No cambiar código, SQL, permisos, YAML, workflows ni recursos para ocultar hallazgos. Las reservas documentales no prueban implementación. Consultar PROJECT.md para sincronizar el contexto común y MODULE_REGISTRY.md para las rutas.
