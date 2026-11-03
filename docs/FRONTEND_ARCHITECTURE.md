# Contrato general de arquitectura frontend — MasterERP + Uonify

Estado: decisiones de arquitectura objetivo para implementación progresiva. Este documento no acredita que los frontends, dominios, pipelines o continuidad de sesión descritos estén implementados. Actualmente solo se trabaja en DEV.

Fuente oficial: `mastererp-platform/docs/FRONTEND_ARCHITECTURE.md`, rama `dev`. Infrastructure y Database conservan copias idénticas en `docs/FRONTEND_ARCHITECTURE.md`; no son fuentes independientes. Este contrato debe leerse antes de modificar frontends, navegación, autenticación, contexto o hosting.

## 1. Responsabilidades del producto

MasterERP es el núcleo de negocio: datos, reglas, procesos, módulos y autorización. Cada dominio conserva sus responsabilidades; presentar una operación en una pantalla o en el chat no cambia quién la ejecuta ni quién posee sus datos.

Uonify es el front general y el chat operativo objetivo en `app.uonify.com`. Coordina la experiencia, la navegación y el contexto de trabajo; utiliza las APIs y herramientas autorizadas de MasterERP. No sustituye sus reglas ni concentra por ello la propiedad de todos los módulos.

El Centro de Agentes (`2.6-agent-center`) crea y gobierna agentes especializados. Uonify puede invocarlos dentro de los permisos y contexto autorizados. Invocar un agente no concede privilegios adicionales ni desplaza la autorización del backend.

## 2. Frontends por módulo principal y navegación federada

Los frontends especializados son independientes por módulo principal. Se incorporan al Front Uonify mediante navegación federada, menú y chat: entradas y enlaces hacia aplicaciones especializadas, y operaciones mediante APIs autorizadas. Uonify permite descubrir y abrir el módulo, sin asumir la ejecución de su interfaz o de sus reglas.

No comenzar con microfrontends embebidos. No se adopta Module Federation, composición remota de bundles o iframes como mecanismo inicial de integración. Compartir bibliotecas de UI o contratos no convierte las aplicaciones en un único despliegue. Cualquier cambio posterior de este modelo requiere una decisión arquitectónica explícita.

Cada frontend de módulo principal tendrá build, artefacto, pipeline, despliegue y rollback propios. Las capacidades internas de ese módulo se integran en esa unidad; no se deduce un frontend desplegable por cada submódulo o pantalla. Esta independencia es una responsabilidad de entrega, no evidencia de pipelines ya existentes.

Se conserva la organización actual: frontend y backend en `mastererp-platform`, recursos funcionales en `mastererp-infrastructure` y datos/migraciones en `mastererp-database`. No se crean, separan o renombran repositorios por este contrato. Tampoco se trasladan carpetas, stacks o código existente como consecuencia implícita de documentarlo.

## 3. Finanzas: una raíz para sus capacidades

`finanzas.uonify.com` es la raíz objetivo del frontend principal de Finanzas. Administración no tiene frontend ni subdominio separado: forma parte de ese frontend financiero.

| Responsabilidad | Carpeta funcional vigente | Entrada web objetivo bajo `finanzas.uonify.com` |
| --- | --- | --- |
| Finanzas | `2.2-finance` | `/` |
| Administración | `2.2-finance/2.2.1-administration` | `/administracion` |
| Contabilidad | `2.2-finance/2.2.2-accounting` | `/contabilidad` |
| BI | `2.2-finance/2.2.3-bi` | `/bi` |
| Otras capacidades financieras | Sus carpetas numeradas existentes | Bajo la misma raíz; rutas concretas pendientes de priorización |

Las rutas web son contratos de navegación; no obligan a renombrar las carpetas numeradas existentes en inglés. Administración, Contabilidad y BI no adquieren un frontend independiente por tener una carpeta, API o stack propios. El nombre técnico del API administrativo y las Lambdas `adm-*` tampoco determina el dominio de una interfaz.

`admin.uonify.com` y `finance.uonify.com` no son destinos vigentes de Finanzas en este contrato. Una referencia anterior a esos nombres solo puede conservarse claramente identificada como histórica. No se establecen redirecciones ni registros DNS por escribir esta decisión.

## 4. Congruencia de las cuatro capas

Frontend, backend, Infrastructure y Database mantienen la misma numeración, jerarquía, límites de responsabilidad y correspondencia de rutas funcionales. Se aplican [el estándar de carpetas](FOLDER_STANDARD.md), [el registro](MODULE_REGISTRY.md) y [la guía de módulos](HOW_TO_BUILD_A_MODULE.md).

En Platform, `frontend/app-shell/` conserva la responsabilidad técnica del shell; `frontend/modules/0-uonify/` y `frontend/modules/2.2-finance/` mantienen sus ubicaciones existentes. Su coexistencia no define dos productos Uonify ni autoriza una reorganización automática. Los directorios técnicos y aplicaciones heredadas se conservan hasta una transición explícita.

La congruencia funcional no exige un recurso AWS, una Lambda, un stack o una tabla por pantalla. Los recursos compartidos se declaran una sola vez en el padre funcional correspondiente; los exclusivos conservan su propietario. Un frontend con rollback propio tampoco obliga a cambiar los stacks backend ya desplegados.

## 5. Identidad, autorización y contexto

Cognito autentica; MasterERP PostgreSQL autoriza. La identidad externa se vincula exclusivamente mediante `issuer + sub` con el usuario interno, nunca por coincidencia de email. Un usuario puede pertenecer a varios tenants y cada tenant tener varias empresas.

Uonify coordina el tenant y la empresa activos como contexto de la experiencia. Los frontends especializados consumen el contrato común de identidad/contexto y deben revalidar su selección al entrar, refrescar o cambiar de usuario. La selección del navegador es una solicitud de contexto, no una prueba de autorización.

Cada API valida siempre identidad, usuario, tenant y pertenencia activos, empresa dentro del tenant cuando corresponda, permisos de la operación y módulos habilitados. Se respetan los overrides de denegación y los controles vigentes de aislamiento. No se incorporan grupos Cognito, emails o un rol universal como sustitutos de esos controles.

La autorización por empresa conserva el contrato backend vigente; este documento no inventa una ACL individual por empresa que aún no esté definida. Reglas funcionales adicionales se acuerdan con el Product Owner antes de implementar el comportamiento afectado.

Ocultar menús, botones o herramientas del chat no sustituye autorización backend. El chat, las pantallas y los agentes usan los mismos controles de negocio. El frontend no accede directamente a RDS ni recibe secretos de base de datos. Cambiar tenant/empresa exige evitar cachés o solicitudes que arrastren el contexto anterior.

## 6. Continuidad entre subdominios

La continuidad de sesión y contexto requiere un mecanismo explícito, versionado y probado. No se asume que dos subdominios comparten automáticamente autenticación, almacenamiento o selección de tenant/empresa.

No transferir access tokens, ID tokens ni refresh tokens en URLs, fragmentos, enlaces de menú, mensajes del chat o parámetros de redirección. Si se utiliza un flujo OAuth de código de autorización, su callback validado y sus protecciones se rigen por el contrato de identidad; un código de un solo uso no es un mecanismo genérico para transportar tokens entre aplicaciones.

Queda pendiente seleccionar y validar cómo cada frontend obtiene o renueva su sesión, cómo recibe/revalida el contexto y cómo funcionan logout, expiración, acceso directo, pestañas simultáneas y cambio de tenant/empresa. Las opciones técnicas deben respetar los estándares existentes; este documento no adopta cookies compartidas, BFF, almacenamiento del navegador o un canal entre ventanas sin diseño y pruebas.

## 7. Dominios y entornos: objetivo frente a evidencia

| Experiencia | Hostname objetivo | DEV y alcance de la evidencia |
| --- | --- | --- |
| Front general Uonify | `app.uonify.com` | Nombre DEV documentado en inventario previo: `app-dev.uonify.com` |
| Frontend principal de Finanzas | `finanzas.uonify.com` | Hostname y publicación DEV de Finanzas no verificados; pendientes de definición |
| Administración, Contabilidad y BI | La misma raíz de Finanzas | Sin subdominios propios; sus rutas pertenecen al frontend financiero |

`app-dev.uonify.com` figura como registro DNS del alojamiento DEV en el [inventario CFN versionado de Infrastructure](https://github.com/eticayservicios/mastererp-infrastructure/blob/9faf6392ac3125df5789c56e502faa8878e5254e/docs/FINANCE_RESOURCE_MAP_DEV.md), cuya base se fechó el 2026-11-02. Esa referencia acredita el nombre configurado documentado previamente, no una nueva prueba de DNS/TLS/HTTP en esta tarea ni la implementación de navegación federada. No se inventa un dominio financiero DEV a partir de una convención.

Los nombres sin sufijo indicados arriba son arquitectura objetivo; no acreditan servicios productivos ni entornos QA/PROD. Una evidencia anterior de `app.uonify.com` debe leerse con su fecha y entorno, no como autorización para publicar allí desde `dev`.

Los dominios personalizados requieren DNS autoritativo, certificados y configuración de hosting explícitos, además de callbacks/orígenes autorizados cuando correspondan. Hostname y marca no conceden acceso ni determinan por sí solos el tenant. Cualquier asociación de dominio con una experiencia o contexto candidato debe resolverse mediante configuración validada y autorización posterior del usuario.

## 8. Decisiones técnicas pendientes

- Protocolo y versión de sesión/contexto entre aplicaciones, renovación y logout; pruebas de aislamiento entre subdominios, tenants y empresas.
- Catálogo de entradas federadas para menú/chat, enlaces profundos y comportamiento ante frontend no disponible o versión incompatible.
- Framework, composición del shell y reutilización de UI dentro de los estándares, sin adoptar microfrontends embebidos por defecto.
- Builds, pipelines, hosting, artefactos versionados y procedimiento de rollback de cada frontend principal; no se crean en esta entrega.
- Nombre DEV y publicación de Finanzas, rutas de otras capacidades y eventuales dominios personalizados, con DNS/certificados/hosting revisados.

El Product Owner amplía progresivamente objetivos, prioridades, reglas y criterios de aceptación. El desarrollador concreta la solución técnica y actualiza el módulo; las IA pueden resolver decisiones técnicas dentro de los estándares. Las decisiones funcionales no definidas se marcan pendientes y se acuerdan antes de implementar el comportamiento afectado. No es necesario especificar todos los módulos por adelantado.

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
