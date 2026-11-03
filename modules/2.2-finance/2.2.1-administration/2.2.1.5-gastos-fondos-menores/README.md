# Gastos y fondos menores

Responsabilidad general: Organizar gastos operativos, caja chica, anticipos y rendiciones.

Estado: pendiente de implementación.

Propietario funcional: Finanzas → Administración; responsable nominal pendiente de asignación.
Dependencias: contexto autorizado de tenant y contratos del padre; reglas y criterios de aceptación se definirán con el Product Owner al priorizar la tarea.

## Submódulos

- [Gastos operativos](2.2.1.5.1-gastos-operativos/README.md)
- [Caja chica](2.2.1.5.2-caja-chica/README.md)
- [Anticipos y rendiciones](2.2.1.5.3-anticipos-rendiciones/README.md)

## Candidato de datos local

Tablas y referencias propuestas: categorias_gasto, gastos, fondos_caja_chica, reposiciones, anticipos, rendiciones y rendicion_gastos; gastos clasifica documentos existentes. Véase el [modelo común](../MODEL.md). Soportes, reservas y controles compartidos pertenecen a Administración. Estado: migraciones locales en revisión; sin aplicación remota ni operaciones de negocio implementadas.

## Evidencia SQL DEV

Migraciones 009–013 aplicadas y reaplicadas por el migrador oficial; no habilita operaciones del backend. Resultados y límites: [validación DEV](../../../../docs/ADMINISTRATION_DEV.md).
