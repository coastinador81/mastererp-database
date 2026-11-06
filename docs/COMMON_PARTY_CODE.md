# Código interno común — candidato local

Fuente: catalogo.terceros.codigo. Copia compatible: proveedores_catalogo.codigo.
producto_proveedores.codigo_proveedor queda excluido. Sin backfill.

## Implementación 041

Se sustituyen únicamente los comandos administrativos party_write (v1) y
party_write_v2 conservando firmas, SECURITY DEFINER, autorización y grants.
Catálogo crea ambos códigos iguales y su actualización no admite código.
Sin trigger: sincronización explícita en ambos comandos, también desde Clientes.
Bloqueos: advisory administrativo por tenant, proveedor, tercero. Catálogo conserva
proveedor -> tercero. El código se modifica en la misma transacción; SQLSTATE 23505
para discrepancia previa o colisión conserva el contrato HTTP 409 existente.
Si v2 cambia código y contactos, difiere la sincronización hasta la actualización
única de contacto: comprueba catalog_version anterior e incrementa una sola vez.
La versión del maestro y el alcance compartido conservan sus controles.
No hay permisos nuevos, cambios de APIs, Compras o frontend.

## Validación

En PostgreSQL desechable con esquema y seeds existentes, aplicar 041, ejecutar
 tests/common_party_code_test.sql y volver a aplicar 041 y repetir el test.
El test usa SET LOCAL ROLE mastererp_app, comprueba current_user, fuerza constraints
y termina con ROLLBACK. Incluye doble rol, idempotencia, contacto+código,
versión obsoleta, colisión y rollback posterior, y alias previo sin sobrescritura.
 scripts/test_common_party_code_concurrency.py usa dos conexiones loopback y una
base qa_ desechable preparada con 041. Configurar MASTERERP_LOCAL_QA_DATABASE,
MASTERERP_LOCAL_QA_USER, MASTERERP_LOCAL_QA_PASSWORD y opcionalmente puerto.
Nunca imprimir credenciales. Requiere pg8000 ya disponible. Las fixtures de carrera
se confirman exclusivamente en la base desechable: descartar esa base después.
Pendiente ampliar carreras mixtas Catálogo/Administración, colisión solo de la
copia y regresión v1/ausencia de proveedor/permisos antes de autorizar publicación.

## Publicación y recuperación

NO publicar este candidato todavía: push a dev puede activar el workflow SQL.
El migrador actual está especializado en 039/040. Esta entrega no modifica su
selección ni reaplica migraciones anteriores. Antes de publicar, preparar y revisar
un lote oficial que empaquete 041 y su test, compruebe baseline/checksums, ejecute
preflight con rollback, aplique 041 en transacción, reaplique y pruebe como app.
Completar primero las pruebas locales pendientes e inventariar discrepancias con
lectura autorizada. No conciliar alias automáticamente. Respaldo DEV conforme al
procedimiento vigente y revisión explícita del diff antes de push autorizado.

Un error de aplicación debe revertir la transacción. Después de commit, una
regresión requiere migración correctiva nueva y revisión: no editar 041 ni
revertir códigos/datos automáticamente. Restaurar funciones antiguas eliminaría
la garantía y solo procede con decisión explícita y una migración de recuperación
revisada. No eliminar tablas, roles, terceros, índices ni modificar snapshots.

## Actualización de validación del candidato

Auditoría de escrituras: 014 party_write y 032 party_write_v2 son los únicos
comandos encontrados que modifican terceros.codigo. Catálogo 024 solo cambia
nombre, estado, contacto y condiciones; sus altas copian ambos códigos. No hay
UPDATE directo concedido a mastererp_app. La implementación 041 conserva esos
contratos; operaciones administrativas usan el bloqueo proveedor -> tercero.

El runner local ahora cubre Administración/Catálogo, Cliente/Proveedor y dos
cambios de código con contactos, con barrera, dos conexiones y comprobación de
una sola versión adicional. Colisiones de ambos espacios y alias previo se
prueban con subtransacciones en common_party_code_test.sql. Las suites existentes
de administración, detalles y Catálogo se incluyen como regresiones de permisos,
versiones e idempotencia. Ninguna prueba PostgreSQL está acreditada sin ejecución.

El migrador oficial empaqueta 041 y selecciona exclusivamente 041 para preflight,
aplicación y reaplicación; no ejecuta 039/040 ni seeds. Comprueba presencia de
modelo compatible, checkout y firma v2, y ausencia de UPDATE directo de app.
Este control no es una conciliación de checksums ni demuestra el estado de DEV:
antes de publicar, comparar versión desplegada y migraciones registradas.
Las cuatro suites seleccionadas se ejecutan con rollback y constraints inmediatos;
el wrapper conserva la transacción del preflight y no permite que el ROLLBACK del
archivo deshaga accidentalmente una migración ya confirmada.

Bloqueo local: intento de inicio de Docker Desktop existente; docker info sigue
fallando porque no existe la tubería dockerDesktopLinuxEngine. No hay psql local.
No se instalaron herramientas. Pruebas SQL y carreras siguen pendientes.

### Pasos exactos antes de publicación

1. Revisar diff propio, 041, manifests, fixtures y versión DEV; no incluir borradores ajenos.
2. Ejecutar SQL y carreras en PostgreSQL desechable cuando funcione Docker. No usar
el runner concurrente sobre RDS: exige loopback y deja fixtures solo en qa_ desechable.
3. Si se autoriza validación DEV: respaldo vigente, inventario de discrepancias en
lectura y revisión del paquete del commit. Desplegar migrador oficial actualizado
antes de invocar; solo DEV us-west-1 y una ejecución a la vez.
4. La invocación habitual apply_model (payload {}) hará preflight rollback, commit
041, reaplicación 041 y regresiones rollback. Supervisar FunctionError y status/tests;
un fallo se propaga con fase, archivo y committed_passes. Detenerse sin reintentar
si falla; rollback de fixtures no revierte los commits de esquema.
5. La concurrencia real en DEV requiere un procedimiento separado autorizado con
fixtures visibles entre sesiones y limpieza acotada; no queda demostrada por el
migrador secuencial ni por estas pruebas con dobles.
6. Publicar solo tras autorización. Markdown y scripts auxiliares fuera de schema,
seeds y tests no activan aplicación según database_apply_required.py. Un cambio
en schema/tests sí la activa; no mezclar la publicación documental con este lote.
Los workflows no se modificaron. Sin push ni invocaciones durante esta tarea.

La configuración anterior de 039/040 se conserva en Git para revisión histórica;
las instrucciones previas de este documento que decían que el selector no estaba
adaptado quedan sustituidas por esta sección. Recuperación: migración correctiva
nueva, nunca backfill de alias ni edición de migraciones aplicadas.
