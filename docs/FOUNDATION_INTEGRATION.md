# Reutilización de la base compartida DEV

Estado: cierre parcial comprobado, base completa NO cerrada. Solo cuenta 277352717693, us-west-1. Los validadores y los health de Administración no prueban capacidades de negocio.

## Contrato de identidad y autorización

Cognito compartido por entorno; conservar issuer/client/scopes y JWT de las API existentes. Vinculación exclusiva issuer + sub a usuario interno activo mediante resolve_external_identity. Nunca asociar por correo ni usar grupos Cognito o platform.admin como acceso universal. El permiso uonify.connections.manage y su override booleano se evalúan en PostgreSQL; false prevalece.

La aprobación previa del propietario permite a cualquier usuario interno activo autenticado crear su propio tenant, cuyo propietario debe ser ese actor. No autoriza registrar identidades por email ni elegir otro propietario. El flag de autorregistro sigue false hasta reparar y validar su ruta real; no basta cambiar configuración.

Tenant es aislamiento y habilitación de módulos. Empresa pertenece a tenant y sucursal a empresa del mismo tenant. La administración de empresas es owner-only conforme al contrato existente; no hay ACL adicional por usuario/empresa definida. Su diseño funcional permanece pendiente del Product Owner.

## Controles que debe reutilizar un módulo

1. Autenticar access token antes de leer secretos o abrir RDS. No aceptar identidad de cabeceras del navegador. Uonify usa claims ya verificados por API Gateway. Onboarding comprueba firma RS256, issuer, client_id, token_use y fechas con claves públicas Cognito incluidas en el paquete: kid desconocido falla cerrado hasta reempaquetar.
2. Conectar exclusivamente con el secreto de mastererp_app y TLS verificado, sin fallback administrativo. Comprobar rol efectivo. Contexto actor/tenant local a la transacción, obtenido después de resolver identidad estable, pertenencia y estados activos. Conexión nueva por petición; cierre y commit/rollback explícitos. No reutilizar contexto global ni valores de otra solicitud.
3. Para operaciones de negocio usar require_capability de Platform backend/shared/tenant-security/tenant_security/foundation_access.py: módulo habilitado y vigente, permiso efectivo y contención empresa/sucursal. Está integrado en connection_access de Uonify, no solo documentado. No usar un tenant_id del cliente como autorización. Onboarding draft/active es control inicial, no habilitación de todo el negocio.
4. Definir el permiso real de la nueva operación conforme al contrato priorizado. No reutilizar uonify.connections.manage para otros dominios ni crear un bypass de owner/plataforma. Los permisos funcionales no acordados requieren decisión del Product Owner.
5. Para lecturas aisladas está disponible request_context, READ ONLY, actor resuelto y limpieza de seis variables, siempre ROLLBACK. Los adaptadores existentes también abren/cerran su propia conexión y contexto local. No confundir este helper con una transacción de escritura.
6. Para escrituras, autorización y efectos deben ser atómicos. Usar create_tenant_with_owner o register_company_once cuando correspondan; no escribir claves de idempotencia directamente con permisos amplios. La huella incluye actor, operación, tenant cuando existe y contenido. Advisory lock serializa una clave. Replays idénticos no duplican; contenido diferente genera conflicto SQLSTATE 23505 que el backend debe mapear a 409 sin mensajes SQL.
7. Se conserva unicidad global de clave del contrato anterior. Claves de otro actor/operación no devuelven su respuesta. Claves antiguas sin huella o expiradas se rechazan; no inventar su contenido ni borrarlas. RDS conserva dos claves previas sin huella: riesgo de conflicto para clientes que intenten reutilizarlas.
8. Auditar actor, tenant, empresa si corresponde, operación, resultado y correlación mediante audit_result, sin cuerpos, tokens, secretos, prompts ni respuestas. Tenant/company SD escriben auditoría SQL; las solicitudes cubiertas emiten auditoría fija en CloudWatch, incluidas denegaciones. No afirmar cobertura de rutas aún no reparadas.

## SQL y despliegue comprobados

006 se concilió por hashes del ZIP AWS con los archivos locales revisados y Git; no se reconstruyó por numeración ni se editó para ocultar drift. 007 se aplicó y reaplicó por el workflow oficial. 008 es una corrección hacia delante: actor activo también para sesiones sin tenant y lectura de idempotencia. Ninguna elimina tablas, tenants ni datos. El FK compuesto de sucursales está validado y no se encontraron relaciones previas incompatibles.

No se detectó un ledger individual de migraciones por los nombres habituales; el migrador reaplica el manifiesto completo dos veces. Los commits/runs, hashes del paquete y cuerpos de funciones RDS son evidencia de versión; no se inventaron registros o fechas de aplicación.

Database conserva deploy-migrator workflow_call y apply con needs, concurrencia y comprobación de FunctionError/succeeded/passed. El empaquetador toma el manifiesto explícito del handler, no glob de candidatos locales. El despliegue actualiza solo el código de la Lambda oficial y verifica SHA/configuración antes de invocarla. No crea otro migrador, SG, endpoint o rol. Las pruebas de acceso usan SET LOCAL ROLE mastererp_app, aserción de current_user y ROLLBACK; ese rollback NO revierte el esquema ya confirmado.

Antes de publicar SQL: PostgreSQL desechable compatible, modelo/reaplicación, pruebas SQL y concurrencia. Snapshot disponible mastererp-dev-before-foundation-20261102171909. Fallos reportan fase/archivo/SQLSTATE/committed_passes; no reintentar automáticamente ni ampliar permisos. Preferir corrección hacia delante. Restaurar snapshot crea otra instancia y requiere revisar recuperación/endpoints explícitamente; restaurar ZIP no revierte SQL.

## Cobertura y límites actuales

- SQL local y RDS: RLS/owner/miembro/ajeno/contextos, sesiones, permisos/overrides, módulo suspendido/caducado, empresa/sucursal, creación y replays de tenants y empresas, con conflicto de contenido y actor ajeno. La concurrencia de escritura (8 tenants y 8 empresas) se ejecutó solo en PostgreSQL desechable; no presentarla como HTTP ni RDS concurrente.
- HTTP DEV: Cognito Code+PKCE y refresh, espacios, estado Uonify con permiso y módulo activo, denegaciones por usuario/tenant/pertenencia inactivos, miembro, ajeno, override y módulo suspendido; cambios consecutivos y lecturas concurrentes sin filtración observada. Onboarding sesiones se crea/lee con aplicación, y asociación a tenant ajeno se rechaza. Evidencia sanitizada en Platform docs/foundation-http-dev.json.
- Las habilitaciones de módulo QA fueron temporales y se restauraron. Tenant sin asignación activa recibe 403; no se activaron módulos de clientes para hacer pasar pruebas. Espacios/login/scopes, hosting y OAuth/Gemini no se modifican.
- Las seis rutas heredadas a funciones retiradas y el aprovisionador interno siguen pendientes. Sus primitivas SQL no prueban sus flujos HTTP. Faltan HTTP de creación/idempotencia/concurrencia de tenant/empresa y cruces empresa/sucursal. El mismo actor con dos pertenencias y permisos distintos fue probado por API en la continuación.
- Admin API qx8nmypdhi conserva propietario mastererp-dev-onboarding y doce rutas inline SAM, junto a ocho rutas de Administración de su stack hijo. No reimportar un OpenAPI parcial ni mover propiedad para resolverlo: preparar reparación compatible que preserve IDs y los recursos del otro dominio. Este lote no ejecuta la reorganización global excluida por el propietario.
- Las ocho funciones de Administración son diagnósticos públicos mínimos por excepción vigente. No se implementa Finanzas. La base no se declara cerrada mientras falten los recorridos funcionales indicados.

## Archivos y validación

Platform: código compartido, handlers y scripts de empaquetado/pruebas. Infrastructure: recursos y reparación selectiva del propietario actual en raíz funcional; no YAML nuevo por Lambda. Database: schemas, tests, migrador y workflows. Conservar numeración y correspondencias existentes, PROJECT.md, AGENTS.md y estándares; no publicar trabajo ajeno.

Ejecutar py scripts/validate_structure.py y git diff --check en los tres repositorios. Platform incluye pruebas de autenticación Linux y scripts/validate_foundation_dev_http.py; Database, scripts/validate_foundation_disposable.py, test_dev_foundation_guard.py y test_migrator_failures.py. Pruebas con dobles son locales y nunca respaldo de ejecución real.

Resultado y matriz detallada: [FOUNDATION_CLOSURE_DEV.md](FOUNDATION_CLOSURE_DEV.md).

Continuación: [resultados nuevos y estado de cada pendiente](FOUNDATION_CONTINUATION_DEV.md). Push solo de código auxiliar despliega el migrador y omite apply; cambios SQL/tests o despacho manual explícito conservan deploy antes de apply.
