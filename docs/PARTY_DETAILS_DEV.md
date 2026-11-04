# Ampliación de proveedores y conexión DEV

Objetivo: sustituir la ficha visual por datos persistidos usando el maestro canónico de terceros y la API administrativa existente en California. No se crea otro maestro, migrador, Lambda o API. 001–031 no se modifican ni se reaplican en esta actualización; 032 se aplica y reaplica mediante el migrador oficial antes de ejecutar pruebas transaccionales.

## Modelo y contratos

| Datos | Propietario y persistencia |
| --- | --- |
| Código, nombre y versión global | catalogo.terceros existente |
| Nombre comercial, persona, identificación fiscal, dirección, medios de contacto y observaciones | contacto JSONB del proveedor canónico catalogo.proveedores_catalogo (024), validado por los comandos de esta entrega |
| Hasta diez contactos y un principal como máximo | personas dentro de contacto del mismo proveedor canónico |
| Moneda y medio preferidos y condición de pago declarada | datos_comerciales JSONB del perfil administrativo por tenant/empresa/rol |
| Días de plazo y pronto pago | Entidades existentes condiciones_comerciales y descuentos_pronto_pago; nueva edición por modificación, sin alterar condiciones usadas por documentos |

La moneda preferida es un código declarado, no un tipo de cambio ni una habilitación de moneda operativa. No se calcula fiscalidad ni se conceden créditos por registrar preferencias. El perfil conserva una versión independiente; modificar condiciones exige profile_version además de la versión del maestro. Los campos nuevos son opcionales y no invalidan registros existentes. No se añaden valores por defecto fiscales o comerciales.

032 conserva parties_read y party_write v1 para sus consumidores existentes. Las funciones v2 validan actor/tenant/empresa/módulo/permisos mediante el contrato actual, serializan idempotencia y maestro, y exponen solo EXECUTE a mastererp_app. No otorgan DML directo ni modifican RLS. El hash de creación incluye los campos nuevos; las llamadas sin extensión mantienen la huella histórica v1 y sus respuestas de replay. Los datos comunes del proveedor requieren autorización de escritura en todas las empresas vinculadas, conforme a 014. Se exige también catalog_version para detectar cambios concurrentes realizados desde Catálogo; el bloqueo mantiene el mismo orden proveedor → maestro de sus comandos existentes. Las condiciones se limitan al perfil solicitado. Auditoría conserva actor, empresa, resultado y correlación; no almacena el contenido de contactos o credenciales.

POST/PATCH conservan las rutas de Clientes/Proveedores y añaden opcionalmente datos_generales, contactos y condiciones. PATCH con condiciones requiere profile_version. GET devuelve esos objetos además del contrato anterior. No se habilita DELETE ni se borran terceros con historial como consecuencia de esta tarea; archivo/eliminación requiere su regla funcional.

## Publicación y recuperación

Se verificaron dev remoto, migrador desplegado y manifiesto 001–031. El migrador coincide con Git para la base y se documenta el inventario local en build/supplier-alignment de Infrastructure, excluido de Git. Snapshot previo: mastererp-dev-before-supplier-032-20261104, disponible antes de cambios. SQL y pruebas nuevas se empaquetan mediante scripts/package_migrator.py; el workflow Apply DEV database model despliega el migrador antes de invocarlo y falla ante FunctionError o respuesta no succeeded/passed.

Las pruebas de party_details_test.sql utilizan fixtures qa-* identificables, SET LOCAL ROLE mastererp_app y comprobación current_user, con ROLLBACK. Prueban persistencia, datos compartidos, separación de condiciones por empresa, replay/conflicto por contenido extendido, versiones de maestro/perfil, formatos, empresa ajena, falta de contexto y ausencia de DML. Las suites existentes se mantienen. Docker instalado no ofrece un motor Linux operativo: no se afirma validación PostgreSQL desechable local; la validación efectiva se realizará en RDS DEV mediante el migrador oficial. El ROLLBACK de pruebas no revierte la migración ya confirmada.

La recuperación normal es hacia delante con nueva migración, conservando columnas, datos e interfaces v1. Revertir ZIP o frontend no revierte SQL. La restauración del snapshot requiere procedimiento explícito; no se ha ensayado ni se elimina la instancia actual. No se amplían permisos ante fallos de pruebas.

## Tumandaito

El propietario autorizó un tenant business propio y una empresa Tumandaito, país VE, moneda VES y zona America/Caracas. Se comprobó su ausencia antes de preparar el alta. La cuenta Cognito se crea en el pool DEV existente con invitación por correo expresamente autorizada; el sub verificado identifica el vínculo explícito issuer+sub. Nunca se asocia automáticamente un usuario interno existente por coincidencia de correo. El bootstrap acotado usa el migrador oficial para el vínculo inicial y SET LOCAL ROLE mastererp_app para tenant, empresa y activación de Finanzas; no cambia grupos ni concede acceso universal. La invitación exige cambio de contraseña en el primer acceso; no se registra su valor.

Los proveedores de demostración solo se cargarán dentro de esa empresa tras validar el esquema, con códigos DEMO-* y datos claramente ficticios. Las pruebas de permisos y concurrencia usarán otro tenant QA aislado y limpieza acotada. No se asigna una cuenta QA al tenant real de Tumandaito. El correo aceptado por Cognito no acredita entrega ni primer login del propietario.

## Conciliación con el trabajo concurrente

Durante el push se detectaron fc61634 y f975c9a de Andrea en dev. Su workflow 41894200019 aplicó y validó 015–031; se conservan intactos. La propuesta local no publicada 016_party_details se renumeró a 032 y se rediseñó para reutilizar el proveedor canónico de 024. No se añaden columnas de contacto duplicadas en terceros. Catálogo y Finanzas comparten tercero_id y el JSON contacto de proveedores_catalogo; los campos desconocidos de contacto se preservan al actualizar los campos aprobados. Las condiciones del perfil son negociadas por empresa; no se sobrescriben ni se interpretan automáticamente los defaults tenant de proveedores_catalogo.condiciones. Su precedencia funcional deberá definirse cuando se implementen operaciones de compra.

La integración vive en el worktree mastererp-database-supplier, basado en dev remoto; el checkout inicial y sus borradores se conservan. El validador Phase 5 ahora comprueba la partición explícita entre baseline confirmado y upgrade, sin exigir reejecutar grants de migraciones ya aplicadas. Mantiene cobertura de manifiesto, pruebas como mastererp_app, prohibición de SQL destructivo y límites de tamaño. El paquete contiene toda la trazabilidad, pero solo aplica/reaplica 032. La propuesta 016 del checkout original no debe publicarse ni aplicarse.

El muestreo posterior se invoca explícitamente con action=seed_tumandaito_suppliers y el sub aprobado. Solo opera sobre el tenant tumandaito y su empresa exacta, exige propietario y SET LOCAL ROLE mastererp_app, usa códigos DEMO-PROV-001..008 y claves idempotentes estables. No modifica ni elimina proveedores existentes. Los ocho registros son deliberadamente ficticios, con dominios example.invalid e identificaciones DEMO-NO-FISCAL; no representan obligaciones reales.

Validación previa: el primer workflow af980a5 falló en fase schema de 032 con SQLSTATE 42601 y committed_passes=0; toda su transacción se revirtió. Se identificó una expresión CASE que necesitaba paréntesis en PL/pgSQL. La corrección exacta se validó en RDS DEV con action=validate_party_details_candidate: schema y party_details_test.sql aprobados como mastererp_app, siempre con ROLLBACK y committed=false. Solo después se publica el SQL corregido para la aplicación oficial. El diagnóstico no admite SQL ni nombres de archivo arbitrarios y no devuelve DETAIL de filas.
