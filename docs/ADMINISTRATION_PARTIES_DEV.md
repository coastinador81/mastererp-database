# Clientes y Proveedores — resultado DEV

Estado: capacidad funcional desplegada y probada con operaciones persistidas y autorizadas, sin frontend. Cuenta 277352717693, us-west-1, API administrativo qx8nmypdhi, Lambdas mastererp-dev-adm-clientes y mastererp-dev-adm-proveedores.

## Publicación y SQL

Platform 5f3a0d8; Infrastructure b341c43 y recuperación cf4c459; Database 8aaf311. [Workflow SQL](https://github.com/eticayservicios/mastererp-database/actions/runs/41562645928): deploy-migrator y apply aprobados. Se aplicó/reaplicó únicamente 014_administration_parties.sql; 001–013 permanecen intactas y no se reejecutaron. El paquete incluye los 14 SQL para trazabilidad, y files_applied registra solo lo ejecutado. Snapshot mastererp-dev-before-parties-20261103014555 disponible antes de publicar. No se ensayó restauración.

No se crearon tablas maestras: terceros y roles del tenant, perfiles por empresa. Se añadió response_payload al almacén compartido para replay estable. mastererp_app no recibe DML directo nuevo: únicamente EXECUTE de funciones autorizadas. Las dos Lambdas usan el secreto de aplicación, TLS verify-full y contexto transaccional nuevo por solicitud. La inspección de las funciones/constraints compartidas es idéntica a la línea base.

## Pruebas HTTP reales

33 comprobaciones aprobadas con access tokens Cognito y rutas JWT, incluidas las siguientes:

| Caso | Resultado HTTP |
| --- | --- |
| Crear cliente/proveedor/perfil de otra empresa | 201 |
| Listar paginado, detalle y actualización persistida | 200 |
| Añadir proveedor al mismo tercero | 201, mismo ID y dos roles |
| Replay idempotente | 200, mismo resultado original |
| Misma clave con contenido diferente | 409 |
| Actualización con versión obsoleta | 409 |
| Dos actualizaciones simultáneas sobre misma versión | 200 + 409 |
| Dos creaciones simultáneas con misma clave/contenido | 201 + 200, un único registro |
| Sin token | 401 |
| Miembro sin permiso, override write=false, módulo deshabilitado | 403 |
| Tenant/pertenencia inactivos y tenant/empresa ajenos | 403 |
| Empresa válida sin perfil de ese tercero | detalle 404, listado vacío 200 |
| Regreso al tenant original después de otros contextos | 200, versión esperada |
| Preflight sin token, origen DEV permitido | 204 |

Antes de limpiar, una inspección independiente en RDS confirmó tres terceros, cinco perfiles, cinco claves de idempotencia, 13 eventos totales y ocho eventos de negocio con actor/empresa/correlación válidos. La limpieza del run qa-parties-4d22c3b37766 eliminó solo sus tenants, empresas, perfiles, maestros, claves, auditoría y rol nuevos. No se modificaron las filas de usuarios QA existentes ni datos de otros tenants. La evidencia de auditoría sintética se conserva como conteos en el informe; sus filas se retiraron con las fixtures.

Pruebas locales: PostgreSQL 17.9 desechable (modelo/reaplicación, siete suites raíz y tres de Administración, dos carreras), cinco pruebas del handler, cinco de seguridad compartida y la prueba de propagación sanitizada de errores del migrador. Las pruebas SQL de comandos utilizan SET ROLE mastererp_app y comprueban current_user. Los validadores estructurales y git diff --check se ejecutaron en los tres repositorios.

## Incidencia real y recuperación

La ampliación CORS en el propietario SAM del API reimportó Body, eliminó ocho rutas health y sus integraciones externas, y cambió IDs internos de rutas/integraciones de Onboarding. Se detectó antes del despliegue funcional. Se canceló el change set pendiente y se confirmó la ausencia física de esos 16 recursos. Se recrearon mediante el mismo stack hijo bajo logical IDs IntegrationRecovered/HealthRouteRecovered, retirando del estado solamente declaraciones de recursos ya ausentes. Los IDs antiguos no son recuperables.

Se conservaron el API/endpoint, los StackId, ocho Lambdas, roles, logs y permisos originales (32 recursos físicos no API), y los hashes de código de las otras seis Lambdas. El hijo contiene 64 recursos; ambos stacks quedaron UPDATE_COMPLETE. Las ocho rutas health volvieron a responder 200. Se documenta el riesgo pendiente de reimportación SAM: no actualizar nuevamente Body/CORS sin plan específico de preservación. No se realizó una reorganización global de stacks.

## Regresiones y límites

Los diez probes de Uonify/Onboarding son idénticos antes y después: siete pasan y permanecen tres 403 previos de administradores en Uonify. No son fallos introducidos por esta capacidad. Espacios y rechazos/lectura de sesión inexistente de Onboarding mantienen sus códigos esperados. No se ejercitó el flujo completo de escritura de Onboarding ni se resolvieron sus bloqueos previos; no se amplían permisos para conseguir que pase.

El alcance termina en Clientes/Proveedores: no hay frontend ni otras operaciones financieras, fiscalidad o aprobaciones. El permiso de empresa conserva contención tenant/empresa del contrato vigente, no una ACL individual nueva. Nombre/código/version del tercero son compartidos entre sus perfiles de empresa; actualizar exige autorización en todas las empresas vinculadas.

Contrato y ejemplos: Platform/docs/ADMINISTRATION_PARTIES.md. Preparación/despliegue y riesgo de SAM: Infrastructure/docs/ADMINISTRATION_PARTIES.md. Para nuevas actualizaciones usar solo Finanzas, no actualizar directamente el hijo ni repetir el cambio de API si no cambia su configuración. Recuperar código mediante change set revisado y artefactos previos; revertir ZIP no revierte SQL. Las correcciones de datos/esquema requieren migración hacia delante o recuperación revisada desde snapshot, nunca borrar maestros para simular rollback.

Evidencias: [publicación SQL](parties-dev-validation.json), [HTTP funcional](parties-http-validation.json), [local](parties-local-validation.json), [regresión previa](parties-regression-before.json), [regresión posterior](parties-regression-after.json).
