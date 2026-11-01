# Validación autorizaciones DEV — pendiente de ejecución real

## Preparación y alcance

No se ha ejecutado SQL remoto ni se han instalado herramientas locales. El push a dev inicia automáticamente Apply DEV database model: no publicar sin revisar el diff y autorizar explícitamente la aplicación a DEV.

El paquete existente copia schema/*.sql, seeds/*.sql y tests/*.sql. Orden explícito del handler: 001 extensiones, 002 core, 003 onboarding, 004 seguridad, 005 autorización, catálogo; reaplica esta fase una segunda vez y finalmente ejecuta onboarding_model_test.sql y onboarding_authorization_test.sql. La segunda pasada comprueba repetibilidad y las pruebas posteriores comprueban los permisos efectivos resultantes.

## Procedimiento posterior a aprobación

1. Revisar propietario de tablas y SECURITY DEFINER: debe ser el migrador de confianza, nunca mastererp_app. Confirmar que mastererp_app no es superusuario ni BYPASSRLS ni miembro de roles elevados. El migrador debe poder hacer SET ROLE mastererp_app; no otorgar esa facultad a clientes.
2. Revisar datos/backup DEV y coordinar una ventana con quienes usan onboarding. Mantener credenciales existentes y región us-west-1.
3. Publicar el commit aprobado y observar la única ejecución automática. deploy-migrator debe terminar antes de apply. No lanzar otra manual en paralelo.
4. Exigir éxito de ambos jobs, ausencia de FunctionError y status=succeeded/tests=passed. La salida solo incluye datos sanitizados. Un error SQL se propaga como excepción Lambda y FunctionError hace fallar apply.
5. Revisar la respuesta de archivos aplicados, schemas, conteo y correlation_id. No considerar éxito de transporte Lambda como éxito SQL.

## Aislamiento de pruebas

Los fixtures usan UUID fijos identificables y correos example.invalid. No usan ON CONFLICT ni actualizan fixtures existentes: una colisión aborta. Se crean como migrador y las comprobaciones de acceso usan SET LOCAL ROLE mastererp_app. La prueba verifica el rol efectivo y vuelve a comprobarlo en los helpers de autorización. Las transacciones terminan en ROLLBACK; el handler ejecuta ROLLBACK también ante fallo. Las actualizaciones sin filtro iniciales solo pueden alcanzar el tenant fixture a través de RLS del actor fixture.

## Riesgos y recuperación

- Cada pasada del esquema se confirma independientemente. Si falla dentro de una pasada, se revierte esa pasada; si falla la segunda o una prueba, una pasada previa confirmada permanece. El ROLLBACK de pruebas NO revierte una migración.
- Restricciones nuevas pueden romper backend que escriba usuarios, membresías, catálogo o idempotencia directamente; debe establecer contexto transaccional validado. El esquema no autentica el valor de un GUC: el backend es la frontera de confianza.
- Crear tenant con propietario ajeno o contexto de tenant presente será rechazado. La idempotencia conserva PK global; colisiones entre usuarios/operaciones fallan sin revelar respuestas.
- Aprovisionamiento probado a nivel SQL (tenant, módulos, empresa), no ejecución end-to-end de Lambdas backend. Revisar contratos backend por separado.
- Si falla: conservar logs sanitizados/correlation_id, detener nuevos despliegues y analizar la fase. No desactivar RLS ni restaurar grants generales. Preparar una corrección hacia delante, revisar y reejecutar el flujo completo. Revertir Git por sí solo no restaura ACL/policies ya confirmadas. Restaurar un backup solo mediante un plan independiente aprobado; no borrar tenants ni tablas para recuperar.

Las pruebas PostgreSQL siguen PENDIENTES. Las verificaciones estáticas no acreditan ejecución, grants de SET ROLE reales ni comportamiento del motor RDS.
