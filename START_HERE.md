# Empieza aquí

`app-dev.uonify.com` es la entrada general DEV. Objetivo: dashboard común con chat y menú, mostrando solo módulos habilitados y autorizados; sus pantallas comparten el espacio, identidad y contexto de Uonify. No es obligatorio usar el chat. Finanzas DEV tiene hosting independiente para desarrollo y pruebas; el primer recorrido de Clientes/Proveedores usa composición en build y rutas hash internas, con resultados reales enlazados desde el contrato. Leer y respetar el [contrato frontend oficial](docs/FRONTEND_ARCHITECTURE.md), fuente Platform con copias idénticas.

MasterERP centraliza operaciones empresariales por módulos; Uonify es su entrada general con dashboard, menú y chat como experiencia objetivo. El tenant delimita acceso y módulos habilitados; una empresa es una entidad organizativa dentro de ese tenant.

Platform mantiene frontend/ y backend/; Infrastructure recursos funcionales; Database RDS, migrador y SQL. Esta copia es mastererp-database.

Para una tarea: [PROJECT](PROJECT.md) → [AGENTS](AGENTS.md) → [guía de módulos](docs/HOW_TO_BUILD_A_MODULE.md) → README afectado y padres. [PROJECT](PROJECT.md) conserva el contexto común y su fuente oficial/sincronización.

Validar con `python scripts/validate_structure.py` (o `py` en Windows) y `git diff --check`. No instalar herramientas solo para leer documentación.

Estado: hosting independiente de Finanzas DEV publicado, Clientes/Proveedores integrados y probados en Uonify; backend onboarding parcial; autorización SQL validada en RDS DEV en 454fec7, sin acreditar backend completo. Infrastructure sigue en transición de stacks. Leer [registro](docs/MODULE_REGISTRY.md) y [hallazgos](docs/DOCUMENTATION_FINDINGS.md). Push a rutas observadas de Database puede ejecutar despliegue/SQL.
