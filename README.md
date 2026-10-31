# MasterERP Database

Modelo de datos, migraciones y pruebas SQL de MasterERP. Tenant es la unidad de aislamiento: un usuario puede pertenecer a varios tenants, con rol y módulos habilitados dentro de cada uno. La jerarquía funcional se replica en `modules/`.

```
mastererp-database/
├── schema/                  Modelo idempotente y definiciones de datos.
├── migrations/              Cambios versionados de transición segura.
├── tests/                   Pruebas SQL estructurales.
├── seeds/                   Sin datos demo.
└── documentation/           Diccionario de datos y decisiones asociadas.
```
