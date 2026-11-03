# Cartera y obligaciones

Responsabilidad general: Organizar los saldos pendientes de cobro y las obligaciones de pago.

Estado: pendiente de implementación.

Propietario funcional: Finanzas → Administración; responsable nominal pendiente de asignación.
Dependencias: contexto autorizado de tenant y contratos del padre; reglas y criterios de aceptación se definirán con el Product Owner al priorizar la tarea.

## Submódulos

- [Cuentas por cobrar](2.2.1.3.1-cuentas-por-cobrar/README.md)
- [Cuentas por pagar](2.2.1.3.2-cuentas-por-pagar/README.md)

## Candidato de datos local

Tablas y referencias propuestas: partidas_cartera, vencimientos y aplicaciones_cartera; principal referenciado desde documentos, sin duplicar facturas. Véase el [modelo común](../MODEL.md). Soportes, reservas y controles compartidos pertenecen a Administración. Estado: migraciones locales en revisión; sin aplicación remota ni operaciones de negocio implementadas.
