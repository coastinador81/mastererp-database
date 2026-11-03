# Gestión de compras

Responsabilidad general: Organizar proveedores y documentos administrativos de compras.

Estado: pendiente de implementación.

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
