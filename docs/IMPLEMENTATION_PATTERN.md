# Puerta de datos para módulos

Una capacidad candidata añade SQL numerado, repetible y hacia delante en
`schema/`, lo registra en `SCHEMA_FILES` y `applied_schema`, aporta una prueba
rollback-only en `tests/` y registra esa prueba en `TEST_FILES`.

La prueba debe ejercer el rol efectivo `mastererp_app`, aislamiento por tenant,
permisos, estados/conflictos y ausencia de DML directo. El SQL usa funciones
controladas, parámetros y contexto autenticado establecido por backend. No se
permiten `DROP`, `TRUNCATE` ni borrados destructivos para resolver una migración.

El código fuente tiene un máximo de 500 líneas por archivo. Ejecutar:

```text
python scripts/validate_phase5.py
python scripts/validate_structure.py
python scripts/validate_foundation_disposable.py --output <archivo-temporal>
```

El validador y PostgreSQL desechable no autorizan aplicar el modelo en DEV.
