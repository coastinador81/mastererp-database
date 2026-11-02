# Candidato local de fronteras compartidas 007

Estado: probado en PostgreSQL desechable, NO integrado en el migrador, NO publicado como migración y NO aplicado en RDS DEV. [Guía común y promoción](FOUNDATION_INTEGRATION.md). Se preservaron los archivos locales previos del propietario de identidad y migraciones.

## Archivos propios del candidato

- schema/007_foundation_boundaries.sql: overlay repetible posterior a 006, sin borrar datos ni desactivar RLS.
- tests/foundation_boundaries_test.sql: fixtures identificables, SET LOCAL ROLE mastererp_app, comprobación de current_user y ROLLBACK.
- tests/onboarding_authorization_test.sql: solo se amplió el fixture propio de prueba con request_tenant_id para la política nueva; no se cambiaron reglas de implementación ajenas.
- scripts/validate_foundation_disposable.py: contenedor PostgreSQL 17.9 ya disponible, sin red, puertos, volúmenes ni conexión RDS; concurrencia real de ocho conexiones por operación.

La aplicación del esquema en el contenedor se confirma antes de ejecutar tests con ROLLBACK. El rollback de fixtures no deshace una migración ya confirmada. El contenedor se elimina completo al terminar; no se eliminaron imágenes ni volúmenes existentes.

## Riesgos concretos de promoción

El índice compuesto y la validación de FK pueden bloquear temporalmente escrituras. Si existen asociaciones históricas de sucursal/empresa de distintos tenants, no se reparan ni se borran: se conserva NOT VALID para las filas previas, se impiden nuevas inconsistencias y RLS las oculta; informar y acordar su recuperación. Revisar que no haya funciones dependientes o una 007 distinta publicada por otro desarrollador antes de integrar.

Las claves de idempotencia heredadas no tienen huella de contenido. No es seguro deducir su petición original: las primitivas nuevas rechazan su reutilización como conflicto. La unicidad global de clave sigue vigente; no se prometió una clave reutilizable en cada tenant. Cambiar esa política exige una transición independiente. Las respuestas SQL de conflicto deben convertirse en HTTP 409 por el backend; esa integración sigue pendiente.

La creación de tenant preserva la firma existente y exige propietario=actor activo con contexto de tenant ausente. La empresa usa el contrato actual de owner del tenant y admite draft durante onboarding; operaciones de negocio requieren tenant activo y guard de módulo/permiso. No se inventó una ACL de empresa por usuario. El PO confirmó autorregistro para cualquier usuario interno activo autenticado; debe conectarse a la API con esa regla, sin groups/platform.admin.

## Publicación bloqueada

El dev publicado solo empaqueta schemas hasta 005 y un test de 14 tablas; la función oficial desplegada incluye 006. Publicar schema/tests ahora dispara el workflow, que actualizaría el migrador desde una base anterior. No se modificaron ni publicaron los archivos locales ajenos para evitarlo.

El propietario debe publicar y conciliar primero 006 y sus cambios de empaquetado/tests. Después integrar 007 y foundation_boundaries_test.sql en el manifiesto oficial, repetir el candidato sobre esa base publicada y promover por Apply DEV database model. No desplegar otro migrador ni invocar apply_model con el paquete anterior para ensayar este candidato.

## Recuperación

Antes de promover: snapshot y parámetros de referencia según el procedimiento vigente, versión del paquete/commit y plan revisado. Si un test remoto falla, reportar phase/file/sqlstate y committed_passes: el modelo puede haber quedado confirmado antes de las pruebas. Detener el workflow y no reintentar automáticamente ni ampliar privilegios. Corregir mediante una migración hacia delante; no quitar restricciones, borrar columnas/datos o restaurar credenciales administrativas en peticiones para lograr un 200.

## Evidencia

Resultados locales sanitizados: [foundation-local-validation.json](foundation-local-validation.json). Los HTTP reales actuales y sus límites se documentan en Infrastructure; no se declaran aprobadas las pruebas HTTP de las primitivas nuevas. Ninguna migración se aplicó en DEV en esta tarea. La verificación de metadatos por la acción existente verify_dev_identity del migrador solo realizó lecturas.
