# Contexto del primer recorrido frontend DEV

Migración nueva 015_frontend_context.sql: función de solo lectura plataforma.current_frontend_context(), ejecutable únicamente por mastererp_app, con search_path fijado y validación de identidad/tenant activos mediante contratos existentes. No concede DML ni modifica RLS o permisos de negocio. Devuelve módulos habilitados, permisos efectivos con overrides y empresas activas del tenant para las que permite administration.parties.read bajo erp.finance. La contención por empresa conserva el contrato 007; no inventa una ACL por usuario.

El backend Uonify la usa después de resolver issuer + sub y establecer contexto transaccional con el secreto de aplicación. GET /v1/uonify/spaces mantiene su respuesta anterior; tenant_id opcional añade context. Las APIs de Clientes/Proveedores siguen autorizando cada operación; este contexto no concede permisos.

El migrador empaqueta 001–015 para trazabilidad, pero aplica/reaplica exclusivamente 015 en esta entrega. Las pruebas nuevas usan fixtures identificadas, SET LOCAL ROLE mastererp_app, verifican current_user y terminan con ROLLBACK. Incluyen un miembro autorizado que no es propietario, tenant ajeno y override de denegación. El esquema se confirma separado de las pruebas; su rollback no deshace el esquema.

Validación desechable local intentada con Docker ya instalado: el motor Linux no estaba disponible y no arrancó. No se declara aprobada esa validación. La ejecución en DEV y su resultado se registrarán tras supervisar el workflow oficial. Recuperación: conservar el paquete anterior; volver al backend anterior evita consumir la función aditiva. No borrar datos ni ampliar privilegios. Backup RDS antes de aplicar; no se declara ensayada una restauración.
