# Tesorería

Responsabilidad general: Organizar cobros, pagos y movimientos de fondos.

Estado: pendiente de implementación.

Propietario funcional: Finanzas → Administración; responsable nominal pendiente de asignación.
Dependencias: contexto autorizado de tenant y contratos del padre; reglas y criterios de aceptación se definirán con el Product Owner al priorizar la tarea.

## Submódulos

- [Cobros](2.2.1.4.1-cobros/README.md)
- [Pagos](2.2.1.4.2-pagos/README.md)
- [Caja](2.2.1.4.3-caja/README.md)
- [Bancos](2.2.1.4.4-bancos/README.md)
- [Transferencias](2.2.1.4.5-transferencias/README.md)
- [Conciliación](2.2.1.4.6-conciliacion/README.md)

## Candidato de datos local

Tablas y referencias propuestas: cuentas_tesoreria, operaciones_tesoreria, movimientos_tesoreria, transferencias, extractos_bancarios, lineas_extracto, conciliaciones y partidas_conciliacion. Véase el [modelo común](../MODEL.md). Soportes, reservas y controles compartidos pertenecen a Administración. Estado: migraciones locales en revisión; sin aplicación remota ni operaciones de negocio implementadas.
