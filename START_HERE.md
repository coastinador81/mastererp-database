# Empieza aquí

Contrato de lectura previa para frontend, navegación, autenticación, contexto y hosting: [arquitectura frontend común](docs/FRONTEND_ARCHITECTURE.md). La fuente oficial está en Platform y las copias deben coincidir.

MasterERP centraliza operaciones empresariales por módulos; Uonify es su entrada conversacional. El tenant delimita acceso y módulos habilitados; una empresa es una entidad organizativa dentro de ese tenant.

Platform mantiene frontend/ y backend/; Infrastructure recursos funcionales; Database RDS, migrador y SQL. Esta copia es mastererp-database.

Para una tarea: [PROJECT](PROJECT.md) → [AGENTS](AGENTS.md) → [guía de módulos](docs/HOW_TO_BUILD_A_MODULE.md) → README afectado y padres. [PROJECT](PROJECT.md) conserva el contexto común y su fuente oficial/sincronización.

Validar con `python scripts/validate_structure.py` (o `py` en Windows) y `git diff --check`. No instalar herramientas solo para leer documentación.

Estado: frontend MasterERP reservado; backend onboarding parcial; autorización SQL validada en RDS DEV en 454fec7, sin acreditar backend completo. Infrastructure sigue en transición de stacks. Leer [registro](docs/MODULE_REGISTRY.md) y [hallazgos](docs/DOCUMENTATION_FINDINGS.md). Push a rutas observadas de Database puede ejecutar despliegue/SQL.
