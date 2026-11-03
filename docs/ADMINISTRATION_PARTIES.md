# SQL 014 — Clientes y Proveedores

Se añade únicamente 014_administration_parties.sql y pruebas como mastererp_app. 001–013 no se modifican. La ruta oficial de aplicación de este upgrade exige perfiles_tercero existente y ejecuta/reaplica solo 014: no reejecuta modelos ni GRANT anteriores. El manifiesto conserva los SQL históricos para trazabilidad del paquete, pero files_applied informa exclusivamente lo ejecutado. No se incorpora un ledger retroactivo ni se inventan fechas de aplicación.

No hay maestros nuevos: se reutilizan catalogo.terceros, roles_tercero y administracion.perfiles_tercero. Se añade response_payload al almacén compartido de idempotencia para replay estable del resultado original. Las funciones SECURITY DEFINER fijan search_path, comprueban capacidades, pertenencia, tenant/empresa, operación y correlación; PUBLIC no tiene EXECUTE. mastererp_app recibe exclusivamente EXECUTE, sin DML nuevo.

Permisos nuevos administration.parties.read/write: concesión inicial a tenant.owner solo al crear el permiso. Overrides explícitos prevalecen; no hay grupos Cognito ni bypass platform.admin. parties_read valida el alcance y devuelve solo perfiles de la empresa solicitada. party_write crea/añade rol y actualiza el maestro compartido; cambiarlo exige acceso a todas las empresas vinculadas. Codigo es una clave canónica tenant, no una regla fiscal.

Pruebas: administration_parties_test.sql usa SET ROLE real, replay/conflicto, dos roles en un tercero, actualización persistida dentro de la transacción, versión obsoleta, ausencia de contexto y ausencia de DML directo. La transacción termina con ROLLBACK. Las fixtures HTTP usan dos tenants nuevos con UUIDs derivados de un run reservado qa-parties-*, tres empresas y un rol propio. Se reutilizan actores QA existentes sin modificar sus filas. El migrador proporciona party_fixture únicamente en DEV y elimina solo las filas de estos tenants derivados; restaura primero los estados propios y no borra usuarios Cognito ni datos existentes.

El backend usa el secreto de aplicación y no credenciales de migración. Auditoría de escrituras en events e idempotencia se confirman atómicamente; los cuerpos y secretos no se registran en logs. No se implementan reglas fiscales/aprobaciones. La autorización por empresa conserva contención del contrato 007, no añade ACL individuales inexistentes.

Evidencia actual: parties-local-validation.json, parties-dev-validation.json, parties-http-validation.json y regresiones antes/después. Restaurar ZIP no revierte SQL; un snapshot requiere revisión de recuperación y endpoint. Correcciones SQL hacia delante; no borrar maestros para revertir el despliegue.

## Resultado verificado DEV

Desplegado: 33 comprobaciones HTTP funcionales aprobadas, con persistencia, idempotencia, versiones, permisos, aislamiento y limpieza acotada. Evidencia principal en Database/docs/ADMINISTRATION_PARTIES_DEV.md y parties-http-validation.json. Se documentan aparte los tres 403 previos de Uonify y la incidencia de reimportación SAM recuperada con nuevos IDs de rutas/integraciones. Las ocho Lambdas conservaron sus IDs y las otras seis su código.
