# Contrato general de arquitectura frontend — MasterERP + Uonify

Estado: contrato de experiencia integrada objetivo, con implementación progresiva y solo DEV. El hosting independiente de Finanzas DEV está publicado; la integración de sus pantallas en Uonify y el dashboard común de módulos siguen pendientes. El estado desplegado se distingue de las decisiones objetivo en la sección 7.

Fuente oficial: `mastererp-platform/docs/FRONTEND_ARCHITECTURE.md`, rama `dev`. Infrastructure y Database conservan copias idénticas en `docs/FRONTEND_ARCHITECTURE.md`; no son fuentes independientes. Este contrato debe leerse antes de modificar frontends, navegación, autenticación, contexto o hosting.

## 1. Responsabilidades del producto

MasterERP es el núcleo de negocio: datos, reglas, procesos, módulos y autorización. Cada dominio conserva sus responsabilidades; presentar una operación en una pantalla o en el chat no cambia quién la ejecuta ni quién posee sus datos.

Uonify es el front general y chat operativo de MasterERP; `app-dev.uonify.com` es la entrada general en DEV. `app.uonify.com` identifica la entrada general objetivo fuera de DEV, sin acreditar un despliegue productivo. Uonify coordina navegación, identidad y contexto de trabajo; utiliza las APIs y herramientas autorizadas de MasterERP. Los módulos conservan sus reglas y datos.

El Centro de Agentes (`2.6-agent-center`) crea y gobierna agentes especializados. Uonify puede invocarlos dentro de los permisos y contexto autorizados. Invocar un agente no concede privilegios adicionales ni desplaza la autorización del backend.

## 2. Un espacio común con chat y módulos

La experiencia objetivo es un dashboard común en Uonify: el usuario accede a chat y a los módulos habilitados para su tenant y autorizados para su usuario. Si solo tiene Finanzas habilitado y autorizado, únicamente verá ese módulo. Cuando se habiliten otros módulos para el tenant, aparecerán en el mismo espacio para los usuarios autorizados. El catálogo backend o una habilitación comercial no prueban que una pantalla esté implementada.

Las pantallas de los módulos se presentan dentro del espacio general de Uonify, conservando navegación, identidad y contexto comunes. No es obligatorio conversar para navegar: el usuario también puede abrir los módulos desde el menú. El chat es otra forma de acceder a operaciones autorizadas, no un paso obligatorio para abrir pantallas.

Los módulos principales mantienen componentes, build, artefacto, pipeline, despliegue y rollback propios, preparados para integrarse en el front general. La independencia de entrega no obliga al usuario a abandonar Uonify ni a usar un subdominio por módulo. Tampoco implica un frontend independiente por cada submódulo o pantalla.

El mecanismo técnico de integración de pantallas sigue pendiente de diseño y validación. Esta tarea no impone iframe, Module Federation, composición de bundles u otra solución, ni declara ninguna implementada. Las referencias anteriores a «navegación federada» como enlaces obligatorios a aplicaciones separadas y la exclusión anticipada de mecanismos quedan sustituidas por este contrato de experiencia; no deciden la solución técnica.

Se conserva la organización de repositorios y carpetas: frontend y backend en Platform, recursos funcionales en Infrastructure, datos/migraciones en Database. Este contrato no mueve código, stacks o recursos ni crea repositorios.

## 3. Finanzas agrupa sus capacidades

Finanzas mantiene sus componentes, build, pipeline y despliegue propios y agrupa Administración, Contabilidad, BI y las capacidades asociadas existentes. Sus pantallas deben integrarse en el espacio general de Uonify. Administración no tiene frontend desplegable ni subdominio separado.

| Responsabilidad | Carpeta funcional vigente | Presentación objetivo |
| --- | --- | --- |
| Finanzas | `2.2-finance` | Módulo dentro del espacio general de Uonify |
| Administración | `2.2-finance/2.2.1-administration` | Capacidad financiera dentro de ese espacio |
| Contabilidad | `2.2-finance/2.2.2-accounting` | Capacidad financiera dentro de ese espacio |
| BI | `2.2-finance/2.2.3-bi` | Capacidad financiera dentro de ese espacio |
| Otras capacidades financieras | Sus carpetas numeradas existentes | Bajo la responsabilidad de Finanzas |

No se establece `/finanzas` como entrada independiente obligatoria. Las rutas internas, rutas de capacidades y enlaces directos se definirán al implementar la navegación; esta documentación no las fija. Las URLs no obligan a renombrar carpetas numeradas ni se deducen de nombres de APIs o Lambdas `adm-*`.

`finanzas-dev.uonify.com` se conserva como acceso independiente de desarrollo y pruebas del frontend financiero. Existe una página inicial pública, pero ese subdominio no es la navegación objetivo del usuario final. No es obligatorio crear `finanzas.uonify.com` en producción. La decisión anterior que lo establecía como raíz obligatoria y fijaba rutas bajo ella queda sustituida; no se elimina ni modifica el hosting DEV.

`admin.uonify.com` y `finance.uonify.com` tampoco son destinos vigentes definidos por este contrato. Las referencias históricas deben identificarse como tales.

## 4. Congruencia de las cuatro capas

Frontend, backend, Infrastructure y Database mantienen la misma numeración, jerarquía, límites de responsabilidad y correspondencia de rutas funcionales. Se aplican [el estándar de carpetas](FOLDER_STANDARD.md), [el registro](MODULE_REGISTRY.md) y [la guía de módulos](HOW_TO_BUILD_A_MODULE.md).

En Platform, `frontend/app-shell/` conserva la responsabilidad técnica del shell; `frontend/modules/0-uonify/` y `frontend/modules/2.2-finance/` mantienen sus ubicaciones existentes. Su coexistencia no define dos productos Uonify ni autoriza una reorganización automática. Los directorios técnicos y aplicaciones heredadas se conservan hasta una transición explícita.

La congruencia funcional no exige un recurso AWS, una Lambda, un stack o una tabla por pantalla. Los recursos compartidos se declaran una sola vez en el padre funcional correspondiente; los exclusivos conservan su propietario. Un frontend con rollback propio tampoco obliga a cambiar los stacks backend ya desplegados.

## 5. Identidad, autorización y contexto

Cognito autentica; MasterERP PostgreSQL autoriza. La identidad externa se vincula exclusivamente mediante `issuer + sub` con el usuario interno, nunca por coincidencia de email. Un usuario puede pertenecer a varios tenants y cada tenant tener varias empresas.

Uonify coordina el tenant y la empresa activos como contexto de la experiencia. Los frontends especializados consumen el contrato común de identidad/contexto y deben revalidar su selección al entrar, refrescar o cambiar de usuario. La selección del navegador es una solicitud de contexto, no una prueba de autorización.

Cada API valida siempre identidad, usuario, tenant y pertenencia activos, empresa dentro del tenant cuando corresponda, permisos de la operación y módulos habilitados. Se respetan los overrides de denegación y los controles vigentes de aislamiento. No se incorporan grupos Cognito, emails o un rol universal como sustitutos de esos controles.

La autorización por empresa conserva el contrato backend vigente; este documento no inventa una ACL individual por empresa que aún no esté definida. Reglas funcionales adicionales se acuerdan con el Product Owner antes de implementar el comportamiento afectado.

Menús, URLs y contexto enviado por el frontend no conceden permisos. Ocultar menús, botones o herramientas del chat no sustituye autorización backend. El chat, las pantallas y los agentes usan los mismos controles de negocio. El frontend no accede directamente a RDS ni recibe secretos de base de datos. Cambiar tenant/empresa exige evitar cachés o solicitudes que arrastren el contexto anterior.

## 6. Identidad y contexto comunes: integración pendiente

El espacio integrado debe conservar identidad, tenant y empresa activos con un contrato explícito, versionado y probado. Cada módulo consume ese contrato común; la API revalida cada operación. La selección visual o una ruta directa no autoriza al actor.

El diseño debe concretar cómo se obtiene o renueva la sesión, cómo se recibe y revalida el contexto, y cómo funcionan logout, expiración, navegación directa, pestañas simultáneas y cambio de tenant/empresa. Debe evitar cachés y solicitudes que arrastren contexto anterior. No se adopta un mecanismo técnico de integración o transporte por este documento.

Para los accesos independientes de desarrollo tampoco se asume que los subdominios comparten automáticamente autenticación o almacenamiento. No transferir access tokens, ID tokens ni refresh tokens en URLs, fragmentos, enlaces de menú o mensajes del chat. Si se usa OAuth de código de autorización, el callback validado y sus protecciones se rigen por el contrato de identidad; no es un canal genérico para transportar tokens entre aplicaciones.

## 7. Objetivo y estado desplegado en DEV

| Experiencia | Decisión vigente | Estado y alcance de la evidencia |
| --- | --- | --- |
| Uonify general | `app-dev.uonify.com` es la entrada general DEV; dashboard común, chat y módulos autorizados | Hosting DEV documentado; el dashboard integrado y las pantallas financieras no se declaran implementados |
| Finanzas independiente DEV | `finanzas-dev.uonify.com` para desarrollo y pruebas | Página pública «Finanzas — MasterERP», «Desarrollo», «Hola mundo» publicada; sin login, datos ni APIs |
| Finanzas dentro de Uonify | Pantallas integradas con navegación, identidad y contexto comunes | Pendiente de diseño e implementación; las rutas internas y enlaces directos no están fijados |
| Producción | `app.uonify.com` como entrada general objetivo; subdominio financiero no obligatorio | No se crea ni acredita producción o QA por este contrato |

El nombre de Uonify DEV consta en el [inventario CFN versionado](https://github.com/eticayservicios/mastererp-infrastructure/blob/9faf6392ac3125df5789c56e502faa8878e5254e/docs/FINANCE_RESOURCE_MAP_DEV.md), con base fechada el 2026-11-02. El hosting financiero y sus comprobaciones del 2026-11-03 constan en [HOSTING.md versionado de Infrastructure](https://github.com/eticayservicios/mastererp-infrastructure/blob/0df8d9c/modules/2.2-finance/HOSTING.md) y en la [publicación DEV final](https://github.com/eticayservicios/mastererp-platform/actions/runs/41638169436). Esa evidencia demuestra alojamiento independiente, no integración de pantallas ni operaciones financieras. No se repiten consultas DNS, AWS o HTTP por esta tarea documental.

Los dominios personalizados requieren DNS autoritativo, certificados y configuración de hosting explícitos. Hostname y marca no conceden acceso ni determinan por sí solos el tenant. Una configuración de dominio/contexto candidato debe validarse y someterse a la autorización del usuario. No se eliminan recursos existentes ni se crean dominios por actualizar esta documentación.

## 8. Decisiones técnicas pendientes

- Diseñar y validar el mecanismo de integración de pantallas dentro del espacio común, con compatibilidad entre las entregas independientes de Uonify y Finanzas; sin imponer una tecnología en esta tarea.
- Definir navegación, menú, rutas internas y enlaces directos, incluida la respuesta ante módulo no disponible o versión incompatible; no asumir una entrada `/finanzas` obligatoria.
- Versionar el contrato de identidad/contexto y probar renovación, logout, expiración, pestañas, cambio de tenant/empresa y ausencia de filtraciones entre módulos.
- Implementar el dashboard con la intersección de módulos habilitados y permisos del usuario; los controles visuales complementan los de las APIs.
- Mantener el build, pipeline, hosting y rollback propios de Finanzas ya existentes; preparar su integración sin eliminar el acceso independiente de pruebas. Las capacidades financieras de UI siguen pendientes.

El Product Owner amplía progresivamente objetivos, prioridades, reglas y criterios de aceptación. Cada desarrollador concreta la solución técnica dentro de los estándares y actualiza la documentación. Las IA deben respetar este contrato; pueden resolver decisiones técnicas dentro de sus límites. Las decisiones funcionales no definidas se acuerdan antes de implementar el comportamiento afectado.

## 9. Fuente oficial y sincronización

1. Editar primero este archivo en `mastererp-platform/dev`. Revisar [PROJECT.md](../PROJECT.md), [AGENTS.md](../AGENTS.md) y los estándares antes de cambiar sus decisiones.
2. Copiar el archivo completo, sin personalizarlo, a la misma ruta de Infrastructure y Database. Revisar previamente sus diffs; conciliar propuestas locales sin sobrescribir trabajo ajeno ni publicarlo accidentalmente.
3. Comparar SHA-256 y enlaces de las tres copias. Publicar los cambios propios en los tres repositorios y comprobar las copias publicadas, no solo las del área de trabajo.
4. Para `PROJECT.md` se mantiene su mecanismo vigente: Platform es fuente oficial, se replica el archivo completo y se compara SHA-256. Los resúmenes de entrada enlazan este contrato; no mantienen versiones alternativas de sus reglas.

Ejemplo documental desde la carpeta que contiene los tres repositorios, después de revisar cambios locales:

```powershell
Copy-Item -LiteralPath mastererp-platform/docs/FRONTEND_ARCHITECTURE.md -Destination mastererp-infrastructure/docs/FRONTEND_ARCHITECTURE.md
Copy-Item -LiteralPath mastererp-platform/docs/FRONTEND_ARCHITECTURE.md -Destination mastererp-database/docs/FRONTEND_ARCHITECTURE.md
Get-FileHash mastererp-platform/docs/FRONTEND_ARCHITECTURE.md,mastererp-infrastructure/docs/FRONTEND_ARCHITECTURE.md,mastererp-database/docs/FRONTEND_ARCHITECTURE.md -Algorithm SHA256
```

Ejecutar los validadores existentes y `git diff --check`; revisar los paths de workflows antes de publicar. Documentar no autoriza cambios de código, SQL, DNS, Cognito, hosting o stacks ni demuestra que esta arquitectura esté desplegada.
