# Reutilización de la base compartida — candidato y requisitos

Estado: base NO cerrada. DEV us-west-1 únicamente. La existencia de health endpoints o validadores aprobados no prueba autorización, RLS ni operaciones funcionales.

## Contrato acordado

El Product Owner confirmó que cualquier usuario interno activo, autenticado con Cognito, puede crear su propio tenant. El propietario solicitado debe ser el actor autenticado. No usar Cognito groups, platform.admin o coincidencias de email para conceder acceso. Conservar access tokens, scopes y el autorizador existentes; vincular exclusivamente issuer + sub a una identidad interna activa.

Tenant es aislamiento y contratación de módulos. Una empresa pertenece a un tenant y una sucursal a una empresa del mismo tenant. El contrato existente reserva administración de empresas al propietario del tenant; no hay una ACL por usuario/empresa definida. La ACL por empresa, sus roles adicionales y permisos específicos quedan pendientes del Product Owner; no inventarlos al desarrollar un módulo.

## Integración Backend preparada, aún sin conectar a handlers

Platform dispone del candidato backend/shared/tenant-security/tenant_security/foundation_access.py. require_capability consulta plataforma.has_current_tenant_capability usando parámetros: módulo, permiso y empresa/sucursal cuando corresponda. SQL 007 exige permiso efectivo, pertenencia/usuario/tenant activos, módulo activo y vigente, y contención empresa/sucursal. Una revocación explícita del permiso prevalece. No pasar un tenant del navegador sin verificarlo.

request_context recibe una conexión ya abierta como mastererp_app y issuer/sub obtenidos del adaptador JWT verificado. Inicia READ ONLY, limpia actor/tenant/operación/correlación/empresa/sucursal, resuelve identidad y fija contexto local. Siempre ROLLBACK. No es una transacción de escritura ni una implementación de login; nunca usar credenciales administrativas para solicitudes ordinarias.

Para escrituras se necesita un comando atómico con su propia transacción, autorización e idempotencia. audit_result acepta solo actor/tenant/empresa/operación/resultado/correlación; no recibe cuerpos, tokens, credenciales, prompts o respuestas. Esta utilidad no se conecta por sí sola a CloudWatch o a los handlers existentes: su cobertura desplegada sigue pendiente.

No activar el guard nuevo hasta aplicar SQL 007 después de publicar y verificar la base 006. El empaquetador actual de Uonify usa lista explícita de archivos y aún no incluye foundation_access.py: añadirlo y conectar el guard será parte de la promoción revisada. No confundir una prueba con dobles en tests con verificación SQL o HTTP.

## Candidato Database local

schema/007_foundation_boundaries.sql (todavía local/no publicado) conserva firmas existentes de creación de tenant y aporta:

- FK compuesta tenant/empresa de sucursal e índice de referencia, sin borrar ni reasignar datos. NOT VALID primero: nuevas escrituras se verifican; validar filas previas solo si no hay inconsistencias. RLS oculta relaciones heredadas incompatibles. Si quedan filas inconsistentes, informar y resolverlas en otra decisión autorizada.
- Contexto activo para onboarding (draft/active permitidos para preparación; suspended/cancelled/deleted denegados). Operaciones de negocio requieren active mediante guard de capacidad. No convertir draft en acceso general a negocio.
- Guard de módulo + permiso con contención de empresa/sucursal; sin inventar una ACL de empresas.
- Huella de contenido en idempotencia, scope de tenant para lecturas y bloqueo transaccional; creación idempotente de tenant y primitiva register_company_once. Clave/contenido distintos dan conflicto; actor/operación ajenos se deniegan.
- Auditoría de escrituras con actor, tenant, entidad/empresa, resultado y correlación; sin payload sensible. La auditoría de denegaciones y de replays por petición debe conectarse en Backend, no se acredita con el único evento de efecto confirmado.

Se conserva la unicidad global de claves del contrato anterior: una misma clave no es reutilizable entre actores/operaciones/tenants; se rechaza sin devolver otra respuesta. Cambiar a unicidad compuesta requiere transición acordada. Las claves antiguas sin huella o expiradas se rechazan como conflicto en las primitivas nuevas; no se inventa su contenido original ni se borran. El backend deberá mapear el SQLSTATE 23505 de conflicto idempotente a HTTP 409 sin exponer mensajes SQL.

## Procedimiento de promoción que queda bloqueado

1. El propietario del trabajo existente publica su base desplegada: schema/006_shared_identity_permissions.sql, manifiesto/driver/helper oficial del migrador, tests de identidad y modelo de 17 tablas, e integración de identidad/artefactos necesaria. No incluirlos en un commit de otro desarrollador.
2. Contrastar ese commit con AWS. Hoy Git dev contiene SCHEMA_FILES hasta 005 y un test de 14 tablas; el Lambda oficial contiene 006 y las tres tablas de identidad existen realmente. Un push SQL puede actualizar el migrador con código anterior y volver a aplicar reglas incompletas.
3. Integrar 007 al final de SCHEMA_FILES y foundation_boundaries_test.sql a TEST_FILES del migrador; confirmar en el ZIP schema 001–007, seed y todos los tests, sin secretos. No modificar ni publicar el manifiesto local ajeno para saltar este bloqueo.
4. Repetir PostgreSQL desechable 17.9 con modelo/reaplicación y concurrencia real. Revisar compatibilidad de claves heredadas y datos inconsistentes de empresa/sucursal antes de aplicar en DEV.
5. Publicar el candidato autorizado mediante el workflow existente (deploy-migrator → apply). No invocar simultáneamente otra aplicación manual. Comprobar archivo/fase/commits confirmados si falla.
6. Corregir y configurar las tres funciones reales de onboarding sin recrear funciones retiradas ni reorganizar stacks: identidad Cognito, secreto de mastererp_app, red privada mínima, JWT/contrato de API y controles comunes. El registro propio debe habilitarse conforme a la decisión del PO, no mediante grupos Cognito. Revisar change set del stack propietario conservando funciones/rutas obsoletas fuera del alcance.
7. Ejecutar todos los casos por HTTP: dos tenants, actor/tenant/membresía inactivos, override false, módulo suspendido, contención de empresas/sucursales y repeticiones concurrentes. Ninguna prueba SQL local sustituye esas verificaciones.

## Límites de esta entrega

Las ocho Lambdas de Administración son diagnósticos. No se implementa Finanzas. Los candidatos no están conectados al runtime desplegado y no certifican cobertura de API/pantallas. Se preservaron los cambios previos del equipo. Consultar en Infrastructure docs/FOUNDATION_DEV_DIAGNOSIS.md y foundation-dev-diagnosis.json; resultados SQL desechables en Database docs/foundation-local-validation.json cuando se registre la validación final.
