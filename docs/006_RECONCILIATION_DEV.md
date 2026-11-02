# Conciliación de la base 006 DEV

Cuenta 277352717693, us-west-1; función oficial mastererp-dev-database-migrator. El paquete desplegado previo tiene CodeSha256 g9qNylzlbmgQi8Ii/6RfdZkvrJEt/PLfDBNbR0jlXUA=. No se reconstruyó la migración por su número ni se alteró SQL 006.

Procedencia: archivos locales preexistentes de identidad, contrastados con los bytes del ZIP actual AWS. Handler, dev_validation.py, schemas 001–006, seed, test de modelo de 17 tablas y test de identidad coinciden normalizando únicamente CRLF. La prueba de autorización local difiere por el candidato 007: se conserva en el working tree y se excluye de esta primera publicación. Su versión Git anterior coincide con la base desplegada.

Se integran solo schema/006_shared_identity_permissions.sql, handler/helper oficial, dependencias puras fijadas, empaquetador explícito y las pruebas de modelo/identidad requeridas. No se incluyen cambios frontend, recursos de hosting, bootstrap IAM/red, ni documentación ajena no necesaria. [Comparación de hashes](006-reconciliation-provenance.json).

El workflow reutilizable conserva workflow_call, secretos existentes y us-west-1. Solo actualiza el código del migrador existente; no crea SG, endpoint, roles ni otro migrador y no cambia su configuración. Empaqueta los SQL del manifiesto, espera la actualización y verifica CodeSha256, State y LastUpdateStatus. Apply mantiene needs deploy-migrator y falla ante FunctionError o resultado distinto de succeeded/passed.

El handler reaplica el modelo; no se identificó un ledger de migraciones individual por hash. La existencia de las tres tablas de identidad y la verificación de rol se comprobaron por la acción de lectura existente. La evidencia anterior de aplicación 006 se conserva: no se inventa una fecha de aplicación mediante un nuevo registro. Un respaldo RDS disponible precede la reaplicación conciliada.

Solo después de comprobar la ejecución automática de esta base se integrará 007. El commit de conciliación no incluye el candidato 007 ni las modificaciones de tests que requieren sus columnas.
