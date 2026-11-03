# Administración — validación real DEV

Cuenta 277352717693, us-west-1, RDS mastererp-dev-data, PostgreSQL 17.9. Solo mastererp-database/dev; sin cambios en otros repositorios, infraestructura física o permisos de escritura de aplicación.

## Publicación y respaldo

Commit de implementación: 17159e0b687dedd7a4273de94ba97b6fc039ee67. [Workflow automático](https://github.com/eticayservicios/mastererp-database/actions/runs/41557866728): changes, deploy-migrator y apply aprobados. [Validador estructural](https://github.com/eticayservicios/mastererp-database/actions/runs/41557866642) aprobado. No se lanzó otra aplicación manual.

Git remoto coincidía con 2631c7a antes de publicar. El paquete anterior coincidía en 001–008 y código tras normalizar saltos de línea. No existe ledger individual de migraciones en RDS; no se inventan registros por archivo. Las migraciones aplicadas no se editaron. Los cambios ajenos se conservaron fuera de los commits.

Snapshot mastererp-dev-before-administration-20261103010411 disponible antes del push. ZIP anterior en el directorio temporal local mastererp-administration-before.zip. No se ensayó restauración. Restaurar código no revierte SQL; una restauración RDS requiere decisión explícita sobre instancia/endpoint. Ante error, detener y conservar fase, archivo, SQLSTATE y committed_passes; no reintentar automáticamente ni ampliar permisos.

CodeSha256 desplegado: P3t+DyXmM5M4/9rxRvOGk6qSEsH5T8Bpj3F2cpso2TI=. Se compararon los 13 SQL y los tres Python del paquete con los archivos revisados. La inspección de funciones y constraints compartidos es idéntica antes y después.

## Aplicación y pruebas

009 referencias; 010 documentos; 011 tesorería; 012 cartera/gastos; 013 integridad/RLS. El handler aplicó y reaplicó el modelo en transacciones separadas y después aprobó las seis suites SQL anteriores. Total informado: 50 tablas, incluidas 29 nuevas de Administración y cuatro maestros canónicos. El rollback de pruebas no revierte el esquema confirmado.

| Comprobación real en RDS | Resultado |
| --- | --- |
| 33 tablas nuevas, RLS, SELECT y ausencia de DML app | Aprobada |
| Constraints validadas e índices válidos | Aprobada |
| Rol efectivo mastererp_app sin superusuario/BYPASSRLS | Aprobada |
| Tenant/empresa, contexto, override, módulo y actores/organizaciones inactivos | Aprobada |
| Integridad, cabeceras/detalles, FK, ajustes y reversos | Aprobada |
| Precisión monetaria, moneda, tipo de cambio y límites | Aprobada |
| Vínculos de idempotencia, condiciones selladas y reservas | Aprobada |
| Dos escritores con la misma versión | Un commit y un rechazo 40001 |
| Sobreaplicación concurrente sobre el mismo saldo | Pendiente remota; aprobada solo en PostgreSQL desechable local |

Las tres suites utilizan UUIDs únicos, un rol sintético propio y rollback integral. Las comprobaciones de acceso ejecutan SET ROLE mastererp_app y verifican current_user. La preparación de fixtures usa el rol de migración; no representa permisos de escritura del backend. No se concedieron permisos a roles existentes.

La carrera remota confirma exclusivamente un actor/tenant/empresa/condición nuevos y elimina esos UUIDs en finally. No crea hechos monetarios inmutables. La carrera monetaria remota necesita diseñar primero fixtures persistentes y recuperación compatible: no se desactivan los triggers para borrarlas y no se declara la evidencia local como remota.

## Regresiones HTTP

Diez comprobaciones antes y después con tokens Cognito reales, sin cambiar estados QA: resultados idénticos. Siete pasan. Tres fallos previos permanecen: administradores A/B y retorno al tenant A reciben 403 en Uonify frente al 200 esperado. Espacios responde 200; sin token 401; miembro/cruce de tenant 403; Onboarding sin token 401 y sesión inexistente autenticada 404. Sin fallos nuevos dentro de esta cobertura.

No se ejercitó el flujo completo de escritura de Onboarding ni OAuth/Gemini. No se amplían permisos para corregir los 403 previos. Las Lambdas de Administración siguen siendo diagnósticos; las tablas no constituyen capacidades del backend implementadas.

## Evidencia y reproducción

[SQL/publicación](administration-dev-validation.json), [HTTP previo](administration-http-before.json), [HTTP posterior](administration-http-after.json), [pruebas locales](administration-local-validation.json), [modelo](../modules/2.2-finance/2.2.1-administration/MODEL.md).

Desde la raíz: py scripts/validate_administration_dev.py invoca solo validaciones explícitas, sin aplicar el esquema. py scripts/validate_administration_http.py --platform ../mastererp-platform --output docs/administration-http-after.json ejecuta los probes de lectura usando el cliente QA existente de Platform. No ejecutar Apply de nuevo solo para validar.

Pendientes: carrera monetaria remota con limpieza compatible, tres 403 previos de Uonify, regresión de escrituras completas de Onboarding, comandos autorizados del backend y reglas fiscales/redondeo/aprobaciones del modelo. No se declara cierre funcional de Administración.
