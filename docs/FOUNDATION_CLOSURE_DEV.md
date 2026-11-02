# Base compartida DEV — resultado y pendientes

Fecha: 2026-11-02. Cuenta 277352717693, us-west-1, ramas dev. **La base completa NO está cerrada.** Se completó conciliación 006, aplicación 007/008 y reparación de sesiones/progreso; quedan recorridos HTTP y legado pendientes. No se implementó Finanzas ni se reorganizaron stacks.

## Conciliación y versiones

Antes: Git publicaba hasta 005/modelo de 14 tablas; AWS contenía 006/modelo de 17 tablas y archivos locales pendientes del otro desarrollador. Se contrastaron bytes del ZIP, normalizando únicamente CRLF, y se integraron selectivamente los archivos necesarios. La prueba de autorización que dependía de 007 se excluyó del primer lote. No se reconstruyó 006 por numeración ni se modificó después de aplicarse.

| Lote Database | Commit de código | Ejecución automática | Resultado |
| --- | --- | --- | --- |
| Base 006 conciliada | 8bd0b5b | [41491486157](https://github.com/eticayservicios/mastererp-database/actions/runs/41491486157) | deploy-migrator y apply correctos |
| Límites 007 | 2a829bd | [41492018133](https://github.com/eticayservicios/mastererp-database/actions/runs/41492018133) | Aplicación, reaplicación y pruebas correctas |
| Instrumentación QA acotada | 8d25db5 | [41502636486](https://github.com/eticayservicios/mastererp-database/actions/runs/41502636486) | Correcta; mismo modelo 007 |
| Corrección hacia delante 008 | 467edee | [41505141804](https://github.com/eticayservicios/mastererp-database/actions/runs/41505141804) | Correcta, cinco archivos de pruebas SQL |
| Prueba positiva de idempotencia de empresas | 3c24386 | [41506822843](https://github.com/eticayservicios/mastererp-database/actions/runs/41506822843) | Correcta, seis archivos de pruebas SQL |

Migrador oficial mastererp-dev-database-migrator, Python 3.12, Active/Successful. **Paquete de la última aplicación SQL: commit 3c24386ae4308d1545b4c63845f2169aa273b189; CodeSha256 MajGlPcTvtrC5KicEJtaoX8D+vLxRdyLhzA9ecU7u1Q=.** ZIP: schemas 001–008, seed 001, seis tests (15 SQL), pg8000 puro Python; sin .env, secretos o binarios Windows. El código auxiliar se actualizó después sin reaplicar el modelo; versión actual y resultados nuevos en [continuación](FOUNDATION_CONTINUATION_DEV.md).

No se encontró un ledger individual de migraciones por nombres habituales. No se inventaron registros retrospectivos: evidencia de versión mediante runs, manifiesto, hashes y comparación de seis cuerpos de funciones RDS con el código revisado. Permanecen 17 tablas. FK branches_tenant_company_fk validado; cero enlaces empresa/sucursal incompatibles. Dos claves de idempotencia previas carecen de huella y se conservan; su reutilización genera conflicto, no reconstrucción artificial de contenido.

008 fue necesaria porque las políticas anteriores aún admitían contexto de actor inactivo en sesiones sin tenant y claves pre-tenant. Se añadió una migración nueva con políticas RESTRICTIVE; no se reescribieron 006/007 aplicadas ni se concedió BYPASSRLS.

## Despliegue conservando propiedad

| Recurso existente | Propietario | Cambio |
| --- | --- | --- |
| Migrador oficial | Database, mecanismo vigente | Código/manifiesto conciliados; deploy antes de apply, espera y verificación SHA/configuración |
| onboarding-session-manager y onboarding-progress-tracker | mastererp-dev-onboarding | Código, Cognito issuer/client, secreto de aplicación, VPC existente; roles limitados al secreto exacto y ENI estándar |
| uonify-google-connection-handler | mastererp-dev-uonify-google-connection | Solo artefacto; require_capability integrado con permiso y uonify.core activo, auditoría correlacionada |
| Admin API qx8nmypdhi | mastererp-dev-onboarding, excepción vigente | Conservadas 20 rutas/integraciones/CORS y sus IDs |
| Agent API ebn01q74hh | Propietarios vigentes | Conservadas dos rutas, autorizador JWT, scopes, integraciones y CORS |
| Finanzas/Administración | Jerarquía vigente | Conservados 48 recursos y código/configuración de ocho Lambdas técnicas; ocho health 200 son solo regresión técnica |

Fuentes de código Platform: e5e657b (reparación Onboarding) y cbef549 (guard/auditoría Uonify). Infrastructure: a833556 (plantilla del propietario actual y scripts con revisión estricta de change set). No se cambiaron Cognito, hosting, DNS, RDS físico ni sus secretos. Se creó el snapshot de respaldo mastererp-dev-before-foundation-20261102171909 y artefactos en buckets existentes; no nuevos SG/subnets/NAT/endpoints/stacks. Las conexiones Lambda reutilizan VPC vpc-048771aa5c0e121bd y SG de aplicación existente.

El 500 de las funciones HTTP activas provenía de KeyError: Attempt to overwrite 'message' in LogRecord, junto con configuración de identidad/datos vacía y autenticación histórica incorrecta. Se valida access token antes de RDS y se usa solo issuer/sub, nunca correo/grupos. Credenciales ordinarias: mastererp_app, rol sin superusuario/BYPASSRLS/CREATEDB/CREATEROLE ni membresías heredadas. TLS verify-full y conexión/contexto nuevos por petición.

Drift actual: Uonify, Finanzas y Administración IN_SYNC. Onboarding DRIFTED exclusivamente por cinco funciones retiradas y seis permisos asociados ya ausentes; se conservaron sus declaraciones históricas sin recrearlas. No se presenta ese drift previo como resuelto. La revisión de hashes de código complementa el drift donde AWS no cubre código o propiedades inline.

## Pruebas reales y alcance

| Escenario | PostgreSQL local 17.9 | RDS DEV | HTTP DEV |
| --- | --- | --- | --- |
| Actor estable, owner/miembro/ajeno, estados y contexto | Aprobado | Aprobado como SET ROLE mastererp_app | 401/403/200 comprobados en rutas cubiertas |
| Override false y módulo suspendido | Aprobado | Aprobado | 403 y recuperación del estado comprobados en Uonify |
| Un actor con dos tenants y permisos aislados | Aprobado | Aprobado | Aprobado en la continuación; ver FOUNDATION_CONTINUATION_DEV.md |
| Empresa/sucursal de otro tenant y asociación cruzada | Aprobado | Aprobado, FK validado | Pendiente; no operación HTTP reparada para ese recorrido |
| Tenant/empresa: replay, contenido diferente y actor ajeno | Aprobado | Aprobado en seis archivos SQL | Pendiente |
| Creación concurrente sin duplicados ni efectos parciales | Ocho peticiones tenant + ocho empresa, aprobado | No ejecutada concurrentemente | Pendiente de operaciones de escritura reparadas |
| Sesiones propias y asociación a tenant ajeno | Aprobado | Aprobado | Crear 201; leer/progreso/editar/completar 200; ajeno 403/404 según contexto |
| Contexto entre peticiones | Aprobado | Aprobado | Secuencial y ocho lecturas concurrentes, 200 propios/403 ajenos |
| Cognito y Uonify autorizados | Firma RSA local y contratos aprobados | Guard SQL aprobado | Code+PKCE, refresh de sesión, espacios y not_configured comprobados |
| Auditoría | Efectos SQL únicos y correlacionados | Aprobado en pruebas SQL | 30 registros estructurados observados; 152 eventos muestreados sin credenciales de prueba |

Total: **53 comprobaciones DEV aprobadas, incluidas 46 verificaciones HTTP**, restauración de campos QA y limpieza de las dos sesiones creadas por estas pruebas. Son un subconjunto cubierto, no certificación de todo el backend. Las pruebas de acceso usan datos identificables, SET LOCAL ROLE con comprobación de current_user y ROLLBACK. El test estructural y la preparación de fixtures usan el rol del migrador; no se presentan como prueba de autorización. La concurrencia local confirma escrituras solo dentro del contenedor desechable. Los efectos HTTP de QA se confirman y limpian/restauran explícitamente; no se confunden con ROLLBACK SQL. Los updated_at de fixtures conservan la actividad de prueba.

Pruebas locales adicionales: seis de autenticación con claves RSA reales y paquete en imagen oficial Python 3.12 Linux sin red/RDS; catorce del handler Uonify; cinco del helper; tres guards QA; una prueba con tres fases de fallo SQL simulado (esquema/reaplicación/tests), propagación del error y committed_passes correctos. Ninguna simulación se presenta como SQL ejecutado en DEV. YAML/Bash del workflow y validadores/diff check de los tres repositorios aprobados.

Los estados/overrides/asignaciones originales de los fixtures QA se verificaron restaurados con lectura posterior. La activación temporal de uonify.core solo permitió probar el guard; no se activaron módulos de clientes. Un tenant sin asignación activa obtiene ahora 403 por el contrato exigido, aunque sea owner. No se implementan OAuth Google ni Gemini ni se acredita regresión de navegador completa con estas pruebas HTTP.

## Pendientes y bloqueo concreto

**GET /v1/modules sigue devolviendo HTTP 500**, comprobado después de la reparación. Su integración apunta a module-catalog-reader eliminada. Es un fallo previo, fuera de las 53 comprobaciones aprobadas. Otras cinco rutas heredadas aún apuntan a funciones retiradas: POST /v1/tenants, GET/PATCH /v1/tenants/{id}/config, GET /v1/tenants/{id}/modules y PUT /v1/tenants/{id}/modules/{moduleId}. No se recrearon funciones ni se retiraron rutas para ocultarlo.

El aprovisionador interno conserva pendientes autenticación/configuración/comando atómico y validación funcional; no se invocó ni se presenta completado por aprobar primitivas SQL. La finalización de una sesión no equivale a aprovisionamiento.

El CORS del Admin API conserva https://admin.dev.mastererp.local y sus cabeceras anteriores; estos tests HTTP no prueban integración desde navegador app-dev ni habilitan su preflight de tenant. Agent API conserva el origen DEV existente. No se modificó frontend.

La reparación de esas rutas requiere un lote compatible con el API inline SAM y las ocho rutas externas de Administración. ReimportApi sobrescribe la definición ([AWS](https://docs.aws.amazon.com/cli/latest/reference/apigatewayv2/reimport-api.html)); no se ejecutó una reimportación parcial ni una transición no validada que pudiera retirar recursos del otro dominio. Hay que demostrar preservación de IDs/propiedad antes de modificar ese Body. No se amplió esta tarea a la reorganización global de stacks excluida por el propietario.

Después: reparar esos destinos/contratos reutilizando funciones permitidas, aplicar los helpers en las escrituras reales, habilitar el registro propio con el alcance aprobado y repetir HTTP de idempotencia/concurrencia y empresa/sucursal. Aún no hay cierre de estos casos. ACL específica por empresa y nuevos permisos funcionales siguen sujetos a decisión del Product Owner.

## Evidencia y recuperación

Guía común: [FOUNDATION_INTEGRATION.md](FOUNDATION_INTEGRATION.md). Database conserva 006-reconciliation-provenance.json, foundation-workflow-results.json, foundation-rds-inspection.json y foundation-local-validation.json. Platform conserva foundation-http-dev.json y onboarding-progress-http-dev.json, sin tokens. Infrastructure conserva foundation-deployed-functions.json, foundation-stack-drift-dev.json y foundation-preservation-dev.json.

Ante fallo: conservar fase/archivo/SQLSTATE y committed_passes; no reintentar automáticamente ni ampliar permisos. El esquema se confirma antes de pruebas y el rollback de fixtures no lo deshace. Preferir migración nueva hacia delante; restaurar snapshot requiere instancia aparte, validación y decisión explícita de recuperación. ZIP/configuración anteriores y change sets se conservan fuera de Git; revertir código no revierte SQL.

El trabajo local ajeno permanece sin publicar. Se compararon hashes contra el inventario inicial y se usaron listas explícitas de staging. Se corrigió una omisión documental previa: Database no tenía los README espejo de 0-uonify/screens/conversation y hello-world; se añadieron sin SQL ni implementar pantallas. Las cuatro capas conservan 106 rutas funcionales coincidentes.
