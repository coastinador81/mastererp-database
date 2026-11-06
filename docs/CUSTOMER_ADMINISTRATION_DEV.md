# Ficha administrativa de Clientes — candidato DEV

Decisión funcional: una ficha fiscal y de contacto común por tercero dentro del
tenant, incluso con doble rol. Condiciones por empresa/rol. Direcciones de entrega,
cuenta, fecha de nacimiento y preferencias del canal permanecen en eCommerce.

044 añade terceros.datos_administrativos nullable. Sin backfill: lectura usa la
ficha común o los datos legacy de Catálogo. Edición controlada establece la fuente
común; proveedores_catalogo.contacto se conserva como proyección compatible. El
PATCH de Catálogo conserva atributos comunes que no envía para evitar borrar
identificación fiscal. phone se mantiene como alias compatible de telefono.
Las firmas SQL/API, versiones, permisos y sincronización de código 041 se conservan.
No se crea un proveedor para registrar un cliente. Catálogo puede editar el mismo
contacto con su autorización vigente; Administración valida el alcance del maestro.

La API administrativa devuelve origen y una referencia mínima de eCommerce
(email de cuenta y teléfono del canal), solo lectura, por tenant/empresa/tercero.
No vincula cuentas por email ni copia dirección de entrega como dirección fiscal.
No se añaden tablas de clientes, rutas, permisos amplios ni recursos AWS.

Migrador oficial: push hace preflight de 044 con rollback; workflow_dispatch con
apply_model=true aplica/reaplica solo 044 y ejecuta suites de Cliente, código común,
Administración, Proveedores y Catálogo. Nunca se reaplican 040/043 en este lote.
Pruebas nuevas con SET ROLE mastererp_app, constraints inmediatos y ROLLBACK.
Validación backend/SQL en AWS DEV, no en PostgreSQL/Docker local.

Publicación: primero preflight SQL; snapshot disponible; aplicación oficial;
paquete de Clientes revisado mediante stack Finanzas/Administración vigente;
regresión HTTP; finalmente publicación frontend. Recuperación: versión previa del
paquete y frontend, manteniendo datos; corrección SQL mediante migración nueva,
no borrar la columna común ni modificar migraciones aplicadas.

La ficha incluye creación, consulta y edición. Situación financiera, documentos,
cobros, crédito/límites y estados no implementados siguen pendientes: sin cifras
simuladas, reglas fiscales inventadas o cambios en Compras/Contabilidad/BI.
