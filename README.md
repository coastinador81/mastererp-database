# MasterERP Database

## Arquitectura frontend

MasterERP conserva datos, reglas, procesos y autorización. `app-dev.uonify.com` es la entrada general DEV: la experiencia objetivo es un dashboard con chat y menú de módulos habilitados para el tenant y autorizados para el usuario. Sus pantallas se presentan dentro de Uonify, con navegación, identidad y contexto comunes; conversar no es obligatorio. Finanzas agrupa Administración, Contabilidad, BI y capacidades asociadas y conserva build/pipeline/despliegue propios. Su hosting `finanzas-dev.uonify.com` existe como acceso independiente de desarrollo y pruebas, no como navegación objetivo del usuario final; no se exige un subdominio financiero en producción ni una entrada `/finanzas`. La integración técnica de pantallas sigue pendiente. Cognito autentica; MasterERP autoriza cada operación por API. Ver [contrato oficial y estado desplegado](docs/FRONTEND_ARCHITECTURE.md).

Entrada rápida: [START_HERE.md](START_HERE.md).

## Mapa físico y referencias

```text
modules/
schema/
seeds/
tests/
migrations/lambda/
infrastructure/
documentation/
docs/
scripts/
.github/workflows/
```

[Permisos de onboarding](documentation/onboarding-permissions.md) y [validación DEV y recuperación](documentation/dev-authorization-validation.md). Las rutas con llaves resumen carpetas existentes, no son nombres literales. Database usa workflows existentes; publicar cambios observados puede aplicar SQL automáticamente. En Platform las pruebas Python de onboarding requieren sus dependencias y, para integración, una base desechable autorizada. Infrastructure no tiene un despliegue consolidado listo: revisar transición de stacks antes de aplicar plantillas.

Modelo de datos, migraciones y pruebas SQL de MasterERP. Tenant es la unidad de aislamiento: un usuario puede pertenecer a varios tenants, con rol y módulos habilitados dentro de cada uno. La jerarquía funcional se replica en `modules/`.

```
mastererp-database/
├── schema/                  Modelo idempotente y definiciones de datos.
├── migrations/              Cambios versionados de transición segura.
├── tests/                   Pruebas SQL estructurales.
├── seeds/                   Sin datos demo.
└── documentation/           Diccionario de datos y decisiones asociadas.
```

## Guía de trabajo

Leer [PROJECT.md](PROJECT.md), [AGENTS.md](AGENTS.md), [CONTRIBUTING.md](CONTRIBUTING.md), [carpetas](docs/FOLDER_STANDARD.md), [desarrollo](docs/DEVELOPMENT_STANDARD.md) y [registro](docs/MODULE_REGISTRY.md). Requisito para validación local: Python disponible; ejecutar `python scripts/validate_structure.py` (en Windows puede usarse `py scripts/validate_structure.py`) y `git diff --check`. No es obligatorio instalar herramientas locales para consultar documentación; el workflow existente Validate structure realiza el control en GitHub.

Estado: estructura funcional creada; las implementaciones y despliegues se distinguen en PROJECT.md y README de cada módulo. No hay un build frontend operativo declarado en este repositorio.
