# Listado y detalle de Ventas — candidato DEV

Fuente de datos: documentos de venta oficiales vinculados a pedidos; sin nuevas tablas ni backfill. 048 añade ventas_leer, índice de creación y amplía la lectura de empresas del contexto para administration.read, conservando lectores de Clientes/Compras.

GET /v1/administration/ventas y GET /v1/administration/ventas/{id}: Lambda existente mastererp-dev-adm-ventas en el propietario Finanzas/Administración. JWT vigente y tenant por header, empresa obligatoria, erp.finance y administration.read. La función SECURITY DEFINER valida alcance antes de leer y filtra cada fila por sucursal/empresa/tenant. Permisos de escritura y roles permanecen iguales. Dinero en strings, búsqueda servidor por número/cliente/pedido y cursor de creación descendente; no se inventan saldos ni estados de pago.

Workflow oficial batch=sales: preflight 048 con rollback y suites anteriores; aplicación explícita aplica/reaplica solo 048, sin repetir 046/047. Backend/SQL se validan en AWS DEV; local solo comprobaciones estáticas y frontend/build. Pruebas nuevas sales_read_test.sql usan SET ROLE mastererp_app, verifican rol efectivo, límites de lectura, contexto de empresas sin permiso de Clientes, búsqueda, paginación, precisión, snapshot histórico y restricciones inmediatas antes del rollback.

Estado: candidato preparado, pendiente de ejecutar y registrar evidencia real. Publicar API antes de activar menú frontend. Sin facturación, cobros, creación manual ni nuevas fuentes. No cambiar propiedad de stacks ni reimportar API con SAM.
