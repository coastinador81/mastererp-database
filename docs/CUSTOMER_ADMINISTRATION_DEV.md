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

## Resultado real en DEV — 6 de noviembre de 2026

044 aplicada/reaplicada: https://github.com/eticayservicios/mastererp-database/actions/runs/42283586504
045 lectura legacy sin backfill: https://github.com/eticayservicios/mastererp-database/actions/runs/42284711153
Frontend: https://github.com/eticayservicios/mastererp-platform/actions/runs/42285586530
Snapshot previo mastererp-dev-before-customer-admin-044-20261106 disponible.
Se corrigió el teléfono de una fixture para cumplir el contrato existente de
Storefront; los preflight fallidos no confirmaron esquema. Sin ampliar permisos.

19 casos HTTP reales aprobados: alta sin proveedor, datos/condiciones persistidos,
lectura independiente, replay y conflicto, doble rol sin duplicar, edición común,
versiones y cambio de código/contactos con un incremento de Catálogo, condiciones
separadas, edición Catálogo conservando fiscales, carreras 201/200 y 200/409,
sin token 401, empresa ajena/override/módulo deshabilitado 403. Limpieza confirmada.

Siete casos de navegador DEV aprobados: login autorizado, alta, consulta API
independiente, edición/contacto, tarjetas sin alturas heredadas, recarga y móvil. Evidencia sanitizada en
[HTTP](customer-admin-evidence/http-validation.json) y
[navegador](customer-admin-evidence/browser-validation.json).
Cinco escenarios locales de frontend con fixtures y build aprobados; no se
presentan como pruebas de persistencia. Backend/SQL se validaron en AWS.

Solo cambió el paquete de mastererp-dev-adm-clientes, Active/Successful;
CodeSha256 sCS4N5Qcb5GT1DXmJThY6kfX4xZ/qKdCrtsCs7umgUY=.
Proveedores conserva exactamente su paquete anterior:
59gddtuynKF17p1qzzm+EaMDSDckm0oSRo+BKTEvvbM=.
Finanzas y Administración UPDATE_COMPLETE, sin recursos nuevos/reemplazos,
ni cambios de API, CORS, Cognito, configuración de RDS, Compras, Contabilidad o BI.

Alcance cerrado: ficha administrativa CRUD, listado/búsqueda paginada y lectura
mínima del canal. No se declara cerrado el circuito financiero ni checkout de
Storefront por estas pruebas. Crédito/límites, saldos/documentos/cobros siguen
pendientes de operaciones reales y reglas priorizadas. No se aplican porcentajes
ni aprobaciones automáticamente, ni se vinculan identidades por correo.

La proyección de lectura 045 también se aplicó/reaplicó con seis suites SQL aprobadas. La corrección visual queda limitada a customer-view; no modifica los CSS globales de Operaciones ni Compras.
