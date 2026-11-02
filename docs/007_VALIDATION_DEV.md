# Base compartida 007 — validación y recuperación DEV

Base conciliada: 8bd0b5b; ejecución 41491486157, deploy y apply correctos. SQL 006 no se modifica. La migración 007 procede del candidato local de la tarea anterior; añade límites empresa/sucursal, contexto activo e idempotencia tenant/contenido con advisory locks. No elimina tablas, tenants ni datos.

Antes de publicar: PostgreSQL desechable 17.9, aplicación y reaplicación, cuatro pruebas con SET LOCAL ROLE mastererp_app y aserción de current_user. Ocho transacciones concurrentes por creación de tenant y de empresa producen una sola entidad, caché y auditoría; contenido diferente se rechaza. Evidencia en foundation-local-validation.json. Estas concurrencias son locales, no HTTP ni RDS.

El paquete usa el manifiesto explícito del handler, no glob de candidatos. Apply depende de deploy-migrator; cualquier excepción SQL produce FunctionError y hace fallar el workflow. Primera y segunda aplicación del esquema se confirman separadamente. Las pruebas SQL usan fixtures identificables y ROLLBACK: ese rollback NO revierte el esquema ya confirmado. El error sanitizado identifica fase, archivo, SQLSTATE y committed_passes; no se reintenta automáticamente.

Respaldo anterior disponible: mastererp-dev-before-foundation-20261102171909. Ante fallo, detener publicaciones, conservar evidencia y revisar committed_passes. Preferir corrección hacia delante; no editar 006 aplicada ni otorgar bypass. Restaurar el snapshot crea una instancia aparte y requiere revisar endpoints/secretos y una decisión explícita; no sustituir ni borrar la RDS actual automáticamente. Restaurar el ZIP previo solo revierte código, no SQL confirmado.

Pendiente: resultados de ejecución 007 DEV y reparación de las operaciones HTTP heredadas. No declarar cerrada la base por aprobar SQL ni health.

## Corrección hacia delante 008

Tras aplicar 007, la revisión detectó que las sesiones sin tenant y las lecturas de claves pre-tenant todavía podían autorizarse solo por ID de actor aunque el usuario estuviera inactivo. 008 añade políticas RESTRICTIVE de actor activo y contexto de tenant activo para idempotencia; no cambia 006/007 aplicadas ni concede privilegios. active_session_context_test.sql prueba realmente como mastererp_app usuario activo, ajeno, inactivo y contexto ausente, con ROLLBACK. Debe pasar PostgreSQL desechable antes de publicarse y el migrador oficial después.
