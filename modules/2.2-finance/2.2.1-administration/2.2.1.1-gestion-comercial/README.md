# Gestión comercial

Responsabilidad general: Organizar clientes, cotizaciones, ventas y facturación.

Estado: pendiente de implementación.

Propietario funcional: Finanzas → Administración; responsable nominal pendiente de asignación.
Dependencias: contexto autorizado de tenant y contratos del padre; reglas y criterios de aceptación se definirán con el Product Owner al priorizar la tarea.

## Submódulos

- [Clientes](2.2.1.1.1-clientes/README.md)
- [Cotizaciones](2.2.1.1.2-cotizaciones/README.md)
- [Ventas](2.2.1.1.3-ventas/README.md)
- [Facturación](2.2.1.1.4-facturacion/README.md)

## Candidato de datos local

Tablas y referencias propuestas: documentos, detalles_documento, relaciones_documento, condiciones_comerciales, descuentos_pronto_pago y perfiles_tercero; terceros y productos se referencian desde catalogo. Véase el [modelo común](../MODEL.md). Soportes, reservas y controles compartidos pertenecen a Administración. Estado: migraciones locales en revisión; sin aplicación remota ni operaciones de negocio implementadas.

## Evidencia SQL DEV

Migraciones 009–013 aplicadas y reaplicadas por el migrador oficial; no habilita operaciones del backend. Resultados y límites: [validación DEV](../../../../docs/ADMINISTRATION_DEV.md).
