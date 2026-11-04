# Gestión de compras

Responsabilidad general: Organizar proveedores y documentos administrativos de compras.

Estado: borradores básicos implementados en DEV; validación HTTP/visual aprobada. Aprobación, emisión y efectos financieros pendientes.

Propietario funcional: Finanzas → Administración; responsable nominal pendiente de asignación.
Dependencias: contexto autorizado de tenant y contratos del padre; reglas y criterios de aceptación se definirán con el Product Owner al priorizar la tarea.

## Submódulos

- [Proveedores](2.2.1.2.1-proveedores/README.md)
- [Solicitudes de compra](2.2.1.2.2-solicitudes-compra/README.md)
- [Órdenes de compra](2.2.1.2.3-ordenes-compra/README.md)
- [Facturas de proveedores](2.2.1.2.4-facturas-proveedores/README.md)

## Candidato de datos local

Tablas y referencias propuestas: las mismas cabeceras/detalles canónicas para solicitudes, órdenes y facturas de proveedor; destinos_compra y detalle_destinos; proveedores referencia catalogo.terceros y roles_tercero. Véase el [modelo común](../MODEL.md). Soportes, reservas y controles compartidos pertenecen a Administración. Estado: migraciones locales en revisión; sin aplicación remota ni operaciones de negocio implementadas.

## Evidencia SQL DEV

Migraciones 009–013 aplicadas y reaplicadas por el migrador oficial; no habilita operaciones del backend. Resultados y límites: [validación DEV](../../../../docs/ADMINISTRATION_DEV.md).

## Borradores conectados DEV

Solicitud → orden → factura de proveedor. Listado paginado, detalle, creación y edición con el maestro de proveedores existente. Una única Lambda Compras, Python 3.12, 256 MB, timeout 15 segundos y logs de 14 días. Las operaciones funcionales usan JWT, contexto validado y mastererp_app con comandos SQL controlados; no hay DML general. El diagnóstico GET /v1/administration/compras/health conserva su respuesta pública mínima.

API existente qx8nmypdhi y autorizador del stack mastererp-dev-onboarding. No se reimporta ni se cambia su CORS. El stack de Administración permanece anidado en Finanzas. Ver [contrato, despliegue y pruebas](../../../../docs/PURCHASE_DRAFTS_DEV.md) y la pantalla compartida [purchases](screens/purchases/README.md).
