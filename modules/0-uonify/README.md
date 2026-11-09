# Uonify

Objetivo específico: Canal conversacional y de voz para consultar y coordinar operaciones con los módulos propietarios (`docs/MODULE_REGISTRY.md:7`). Por decisión del dueño (D1, 08-11-2026), `0-uonify` acoge además toda la app de Uonify de https://dev.uonify.com, en `0.2-app`.

Responsabilidad: en database, qué datos de Uonify existen, dónde viven y cómo se cambian sin tocar por accidente la base compartida.
Estado: reglas escritas. Uonify no tiene SQL propio en la RDS compartida; `0.2-app/migrations` guarda las 139 migraciones de su base propia (D4), en git desde `48bbbfa` (PR #4, 08-11-2026).

## Contrato y estado de esta capa

Código: 0. Nombre/ruta: `0-uonify`. Propietario funcional: el dueño de Uonify (Product Owner). Propietario de los datos: Uonify, solo de los suyos; los datos de la RDS compartida pertenecen al módulo que define sus entidades y no se copian.

Capa: datos. Dependencias: para SQL en la RDS compartida, identidad, tenant y permisos de Plataforma Base (`plataforma.*`); para la base propia, la API de Uonify en platform (`backend/modules/0-uonify/0.2-app`), que aplica sus migraciones. Exclusiones: datos y SQL de otros módulos; el migrador, `schema/`, `seeds/`, `tests/` y la RDS, salvo decisión del dueño (ver Reglas comunes, sección 7). APIs/eventos/MCP: ninguno en esta capa; no se declaran disponibles por existir la carpeta.

Estado verificable (`dev` en `2d062f2`, 08-11-2026): `schema/` llega a la 048 y ningún fichero es de Uonify; solo hay referencias del equipo (sección «Esta capa: database»). `modules/0-uonify` tiene este README, `screens/conversation/` y `screens/hello-world/` (del equipo, solo README) y `0.2-app/` (README, `.gitignore` y 139 `.sql`, con la huella que da su README). Una carpeta o un README no acreditan implementación.

Validaciones: `python scripts/validate_structure.py` (orientativo) y ver Reglas comunes, sección 10. Pendientes: SQL de Uonify en la RDS compartida, solo si el dueño lo decide.

<!-- uonify-reglas-comunes:start -->
## Reglas comunes de Uonify (0)

Bloque idéntico, byte a byte, en los 4 README raíz de `0-uonify` (platform backend y frontend, infrastructure y database). Lo fija el dueño (propietario y Product Owner de Uonify); «el equipo» y «el arquitecto» son los de MasterERP. Dentro de `0-uonify`, las excepciones del dueño prevalecen sobre la norma del equipo que contradigan (`AGENTS.md:7` y `:32`); fuera, rige el estándar del equipo. Las rutas son relativas a la raíz de cada repo.

### 1. Dónde vive Uonify

| Capa | Repo | Carpeta |
| --- | --- | --- |
| Backend | `mastererp-platform` | `backend/modules/0-uonify` |
| Frontend | `mastererp-platform` | `frontend/modules/0-uonify` |
| Infraestructura | `mastererp-infrastructure` | `modules/0-uonify` |
| Base de datos | `mastererp-database` | `modules/0-uonify` |

`eticayservicios/uonify-front` y `eticayservicios/uonify-backend` están congelados desde el 08-11-2026: ni push, ni ramas, ni PR. Uonify se desarrolla solo en estos 3 repos.

### 2. Mapa 0.x

| Código | Carpeta | Qué contiene | Estado |
| --- | --- | --- | --- |
| 0 | `0-uonify` | Raíz: estas reglas y piezas heredadas del equipo, que se describen en la sección de cada capa | Existe en las 4 capas |
| 0.1 | `0-uonify/0.1-corporate-landing` | Reservado por el equipo (`docs/MODULE_REGISTRY.md:8`) | Sin carpeta en ninguna capa |
| 0.2 | `0-uonify/0.2-app` | La app de Uonify de dev.uonify.com: web, API, workers, voz y Estudio | Existe en las 4 capas; estado y evidencia en su README |
| 0.3 | `0-uonify/0.3-nexus` | Nexus: aplicación transversal para conexiones autorizadas de la plataforma | Existe en las 4 capas; hosting DEV definido y pendiente de despliegue |

Áreas futuras de 0.2.x: viven hoy dentro de `0.2-app`; no se crean carpetas vacías. Cada área recibirá el siguiente número libre (0.2.1, 0.2.2…) solo cuando su código se separe, y nacerá a la vez en las 4 capas. D1 (08-11-2026): Estudio, ArtCraft, Amazon y el cobro van en 0, aunque el registro del equipo tenga `2.11-studio`, `2.3.5-product-content`, `2.3.6-marketplaces` y `1.2.x`; el encaje lo decide el dueño con el arquitecto.

| Área | Qué abarca |
| --- | --- |
| Uony | Cerebro y voz |
| Estudio | Motor de creación de vídeo y postproducción ArtCraft |
| Producto | Ficha, materiales y GPSR |
| Conexiones | Drive, Google Cloud y Amazon |
| Cuenta y cobro | Cuenta del cliente, suscripción y pagos |
| Alta | Registro y alta de clientes |
| Consola de administración | Gestión interna de Uonify |

### 3. Excepciones del propietario (08-11-2026, según `AGENTS.md:32`)

| Excepción | Alcance |
| --- | --- |
| Todo Uonify en 0 (D1) | Backend, frontend, infraestructura y base de datos de Uonify van en `0-uonify/0.2-app`, también lo que el registro del equipo sitúa en otros módulos (sección 2), frente a la propiedad por dominio de `PROJECT.md:19`. |
| Ramas y PR | Solo `dev` y `main`; `prod` la crea el arquitecto cuando decida. Cada cambio va en una rama corta con PR a `dev`, fusionado el mismo día (sección 5), en lugar de trabajar directamente en `dev` (`AGENTS.md:23`). |
| Revisión y fusión de PR | Regla del dueño: «pr que abre, pr que se fusiona con dev». Hoy no hay revisor asignado: quien abre el PR revisa su diff con la sección 10 y lo fusiona el mismo día, sin esperar a otro revisor, en lugar de «solicitar revisión» (`CONTRIBUTING.md:9`). La revisión humana que pide `CONTRIBUTING.md:11` la acuerda el dueño con el arquitecto (pendiente). |
| README como única documentación | Las reglas y el estado de cada carpeta van en su README, que se lee antes de trabajar y recibe cada regla nueva. Ningún `.md` nuevo si el dueño no lo pide; los `.md` existentes del equipo se respetan. |
| Solo dev.uonify.com | Todo lo de Uonify en DEV (web, API, OAuth, CORS y callbacks) apunta a `https://dev.uonify.com`. `app-dev.uonify.com` no se usa ni se propone para Uonify, aunque lo citen documentos del equipo (`START_HERE.md:3`). |
| Nexus DEV independiente | Excepción del dueño: Nexus (`0.3`) usa `https://nexus-dev.uonify.com` como aplicación transversal independiente, accesible desde el lanzador. Su alcance es solo el frontend estático DEV; no concede sesión, permisos ni acceso a datos. |
| 500 líneas con lista cerrada (D3) | Todo fichero nuevo o modificado tiene como máximo 500 líneas (`docs/DEVELOPMENT_STANDARD.md:5`). Por presión comercial, se exceptúa solo una lista cerrada de ficheros que ya corren en DEV y llegan como copia exacta; cada capa la publica en el README de su `0.2-app`, en su sección de excepción de 500 líneas. La lista no crece: quien toca uno de esos ficheros lo parte en ese mismo cambio y lo saca de la lista. Las migraciones ya aplicadas no se editan nunca. |
| Puerta y publicación de la web en platform | Las CloudFront Functions de la puerta de dev.uonify.com y los scripts que publican la web y la puerta viven en platform `frontend/modules/0-uonify/0.2-app/edge`, junto a la web y a las páginas legales de la puerta, frente a `AGENTS.md:53` de platform e infrastructure, que asigna a infrastructure la operación de publicación. Se publica a mano, con el usuario de AWS del dueño y desde un clon de platform en `dev`; GitHub no publica (decisión del dueño, 08-11-2026). |
| Sustrato de DEV (D6) | DEV corre en una EC2 arm64 de eu-west-1 con Docker Compose, PostgreSQL propio e inicio de sesión directo con Google; el estándar del equipo es us-west-1, Lambdas arm64 detrás de API Gateway, la RDS compartida y Cognito. Sigue vigente como excepción; alinearlo, si el dueño lo decide, será un proyecto aparte que empieza por una copia de la base de DEV. |

Otras excepciones, con su alcance escrito en otro README (D4 la decidió el CEO al aplicar la regla del dueño «database para la base de datos» y aún le falta su confirmación expresa, `AGENTS.md:32`):

- D4, solo en database: las migraciones de la base propia van en `modules/0-uonify/0.2-app/migrations`, fuera de `schema/` (README de ese `0.2-app`).
- Manual de identidad corporativa (platform `frontend/modules/0-uonify/identidad-corporativa/`): desde el 08-11-2026 es el canon de todo lo visual de Uonify y prevalece sobre `docs/UX_UI_STANDARD.md`, que sigue rigiendo las interfaces administrativas de MasterERP. La regla completa está en el `README.md` de la raíz de cada repo.

### 4. Antes de tocar nada

1. Leer este README, el de la subcarpeta que se va a tocar (por ejemplo, `0.2-app`) y, en la raíz del repo, `AGENTS.md`, `CONTRIBUTING.md`, `PROJECT.md`, `README.md`, `START_HERE.md`, `docs/FOLDER_STANDARD.md`, `docs/DEVELOPMENT_STANDARD.md` y `docs/HOW_TO_BUILD_A_MODULE.md` (`AGENTS.md:7` y `:15`). Si se toca interfaz, autenticación o hosting, además `docs/FRONTEND_ARCHITECTURE.md` (`AGENTS.md:5`) y `docs/UX_UI_STANDARD.md` (bloque UX/UI de `AGENTS.md`); en lo visual de Uonify manda el manual de identidad corporativa (sección 3).
2. Si un documento de Uonify anterior al 08-11-2026 que está fuera de estos repos (por ejemplo, las reglas del árbol local del dueño) choca con este bloque («sin commit ni push», «no hay git»…), manda este bloque.
3. Trabajar en un clon propio y comprobar rama, estado y PR abiertos sin pisar cambios ajenos: `git fetch origin && git status --short --branch && gh pr list --state open`.

### 5. Cómo se hace un cambio

1. Rama corta desde `dev` al día: `git switch dev && git pull --ff-only origin dev && git switch -c uonify/<tema>`.
2. Un cambio pequeño y de alcance único. Commit en español con prefijo `feat`, `fix`, `docs` o `chore`; por ejemplo, `git commit -m "docs(0-uonify): reglas comunes en los README"`.
3. Comprobaciones de la sección 10 y subida: `git push -u origin uonify/<tema>`.
4. PR solo si puede fusionarse hoy, y siempre contra `dev`: `gh pr create --base dev --title "…" --body "…"`. La rama por defecto del repo es `main`: sin `--base dev`, el PR iría a `main`. La descripción dice el repositorio, el módulo, el recurso afectado y si el cambio toca código, infraestructura o ambos (`AGENTS.md:55` de platform e infrastructure), qué lanza la fusión (sección 6) y qué se ha probado.
5. Justo antes de fusionar, con `git branch --show-current` en `uonify/<tema>` (nunca en `dev` ni `main`), poner la rama al día sin reescribirla y repetir las comprobaciones si `dev` trajo cambios: `git fetch origin && git merge --no-edit origin/dev && git push origin uonify/<tema>`.
6. Fusionar el mismo día, tras las comprobaciones de la sección 10, y borrar la rama, porque el borrado automático no está activo y solo puede activarlo la cuenta `eticayservicios`: `gh pr merge <n> --merge --delete-branch` y, después, `git switch dev && git pull --ff-only origin dev`.

Prohibido:
- Push directo a `dev` o `main`, y cualquier `--force` o `--force-with-lease` (`docs/DEVELOPMENT_STANDARD.md:29`: sin force salvo autorización específica).
- PR contra `main`, ramas largas, PR abiertos de un día para otro (el que no se puede fusionar hoy se cierra hoy) y tocar ramas o PR ajenos.
- Cambiar ajustes, secretos, variables, entornos o protecciones del repo: la cuenta `uonify` solo tiene rol write y eso corresponde a la cuenta `eticayservicios`.

### 6. Qué despliega cada fusión a dev

Antes del PR, comparar `git diff --name-only origin/dev...HEAD` con los `paths:` de `.github/workflows/*.yml`; cada workflow se dispara también con su propio YAML. Si se lanza algo más que «Validate structure», se dice en el PR antes de fusionar; si es un workflow del equipo, además hace falta decisión del dueño (sección 7). Después de fusionar, se confirma con `gh run list --commit "$(gh pr view <n> --json mergeCommit --jq .mergeCommit.oid)"`.

| Repo | Ruta tocada | Qué lanza la fusión en `dev` |
| --- | --- | --- |
| Los 3 | Cualquier ruta, y también cada PR | «Validate structure» (`structure.yml`): orientativo, no bloquea |
| platform | En `frontend/modules/0-uonify`, fuera de `0.2-app`: `index.html`, `src/**`, `styles/**`, `**/*.jsx`, `**/*.tsx`, `auth-config.json`, `vite.config.js`, `package*.json`, `.env.dev` y `.gitattributes`; además, `frontend/.gitattributes`, `frontend/shared/auth/*.mjs`, `frontend/app-shell/src/**` y varias `src/**` de 2.1, 2.3 y 2.10 | `publish-uonify-dev.yml`: republica la app del equipo en su hosting, no en dev.uonify.com |
| platform | En `frontend/modules/0-uonify`: `auth-config.json`, `components/Conversation.jsx` y `components/ShellIcons.tsx`; además, `frontend/app-shell/src/**` y `frontend/shared/auth/**` | También Finanzas, Ecommerce o la tienda, según el fichero (`publish-finance-dev.yml`, `publish-ecommerce-dev.yml`, `publish-storefront-dev.yml`) |
| platform | `frontend/modules/0-uonify/0.2-app/**` (web y `edge/`) | Solo «Validate structure»: `publish-uonify-dev.yml` excluye esa ruta desde `c4954c2` (PR #8; D5, aplicada el 08-11-2026) con su último patrón, `'!frontend/modules/0-uonify/0.2-app/**'` (`:36`). Quitar esa exclusión es tocar `.github/workflows` (sección 7). ⚠ Si se añade detrás otro patrón que alcance `0.2-app`, vuelve a dispararse; lo detecta el `gh run list` de esta sección |
| platform | `backend/modules/0-uonify/**`, los README de `0-uonify` y `0.2-app`, `docs/` | Solo «Validate structure» |
| infrastructure | `modules/0-uonify/**` | Solo «Validate structure» (`publish-agents-uonify.yml` vigila únicamente `modules/2.6-agent-center/agents-*`) |
| database | `schema/**`, `seeds/**`, `tests/**`, `migrations/lambda/**`, `scripts/package_migrator.py`, `.github/workflows/deploy-migrator.yml` | `apply-dev-database.yml`: redespliega el migrador y, si cambian `schema/`, `seeds/` o `tests/`, valida contra la RDS DEV, con datos reales, dentro de `BEGIN…ROLLBACK`; el `COMMIT` solo llega lanzándolo a mano con `apply_model=true` |
| database | `infrastructure/rds-dev-us-west-1.yaml` | ⚠ `deploy-dev-rds.yml` despliega la RDS compartida, que no tiene protección contra borrado. No se toca nunca |
| database | `modules/**` | Solo «Validate structure»: `modules/` no ejecuta nada (`docs/HOW_TO_BUILD_A_MODULE.md:42`) |

Ninguna fusión publica dev.uonify.com ni despliega su backend: la web se publica a mano (README de platform frontend `0.2-app`) y el backend corre por digest (README de platform backend `0.2-app`).

### 7. Lo que no se toca sin decisión del dueño

- Nada fuera de `0-uonify`: ni `frontend/app-shell`, ni `frontend/shared`, ni otros módulos, ni `.github/workflows`, ni los recursos AWS del equipo (Cognito, API Gateway, hosting y RDS).
- Dentro de `0-uonify`, las piezas heredadas del equipo (detalle en la sección de cada capa): el código de la raíz de `frontend/modules/0-uonify`, del que dependen `app-shell`, Finanzas y Ecommerce; `backend/modules/0-uonify/lambdas/`; `modules/0-uonify/resources.yml` y `FRONTEND_DEPLOYMENT.md` en infrastructure, y `modules/0-uonify/screens/` en database.
- ⚠ `infrastructure/rds-dev-us-west-1.yaml` de database no se toca nunca. Tampoco el migrador (`migrations/lambda/`) ni `schema/`, `seeds/` y `tests/`, que llegan a la RDS compartida: las migraciones de la base propia de Uonify van en database `modules/0-uonify/0.2-app/migrations` (D4), que ningún pipeline ejecuta.
- Las variables de Actions `UONIFY_DEV_BUCKET` y `UONIFY_DEV_DISTRIBUTION_ID` de platform (`publish-uonify-dev.yml:69-70`) son del equipo: nunca se pide que apunten a recursos de dev.uonify.com, ni que se amplíe el rol que asume ese workflow, `mastererp-dev-uonify-frontend-github-role`, que hoy solo puede escribir en el bucket y la distribución de app-dev (infrastructure `modules/0-uonify/resources.yml:199-236`). Con ambas cosas, la app del equipo pisaría la web aprobada.
- Los documentos del equipo en la raíz de cada repo (`AGENTS.md`, `CONTRIBUTING.md`, `PROJECT.md`, `START_HERE.md` y `README.md`) y en `docs/`. Solo hay una salvedad, que no necesita otra decisión: al crear una carpeta numerada de `0-uonify`, se añade su fila en `docs/MODULE_REGISTRY.md` (sección 11). Si el dueño decide cambiarlos, se sigue la sección 11.
- Nadie escribe al equipo desde Uonify (ni mensajes, ni issues, ni comentarios en sus PR): lo que le afecte se le pasa al dueño, que lo lleva al arquitecto.

### 8. Secretos y datos

- Los secretos del DEV de Uonify están en la cuenta AWS compartida 277352717693:
  - En SSM Parameter Store (SecureString con `alias/uonify-dev`, eu-west-1, bajo `/uonify/dev/`): los del backend (`run/*`) y el secreto de origen (`edge/origin-verify`).
  - Solo en el KeyValueStore de CloudFront `uonify-dev-gate`: el hash de la credencial de la puerta y la clave HMAC de su cookie. Los pone el dueño con `set_gate_credentials.sh` (platform `frontend/modules/0-uonify/0.2-app/edge`); nadie más los lee ni los copia.
  - En la base propia de Uonify, cifrados con `encryption-key`: los tokens de Google y Amazon de cada cliente.
- Nunca se sube: `.env` reales (solo `*.example` con valores falsos), claves, tokens, contraseñas, JSON de clientes OAuth, valores de SSM o KVS, copias reales de la configuración de CloudFront, volcados o copias de bases de datos, listas piloto u otros ficheros con UUID de usuarios, salidas de verificación con IDs, correos personales, grabaciones ni datos reales de clientes o del dueño.
- Nada valioso en el navegador: ni claves, ni precios internos, ni IDs de proveedor.
- Antes de subir código a una carpeta, se le añade su `.gitignore` (el del repo no cubre lo de Uonify). Antes de cada push, escaneo desde la raíz del repo: la lista de ficheros no puede traer `.env` reales, `.pem`, `.key` ni volcados; cada coincidencia del segundo comando se revisa y solo valen valores falsos evidentes de prueba. Las líneas añadidas con `password`, `secret` o `token` también se revisan.

  ```bash
  git diff --name-only origin/dev...HEAD
  git diff origin/dev...HEAD | grep '^+' | grep -nE '(AKIA|ASIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|GOCSPX-|ya29\.|1//0[0-9A-Za-z_-]{20}|(sk|rk)_(live|test)_|whsec_|gh[pousr]_[0-9A-Za-z]{36}|github_pat_|eyJ[0-9A-Za-z_-]{20,}\.eyJ|PRIVATE KEY|HeaderValue'
  git diff origin/dev...HEAD | grep '^+' | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | grep -viE '@([a-z0-9-]+\.)*(example|test|invalid|localhost)$|@example\.(com|net|org)$' | sort -u
  ```

  El tercer comando lista todos los correos que no son de dominios reservados. Solo valen buzones genéricos (`hola@`, `persona@`…); una dirección o un nombre de persona real detiene el PR. Lo mismo se revisa en los mensajes de commit y en el cuerpo del PR (`git log origin/dev..HEAD --format=%B`).

### 9. Calidad, pruebas y gasto (Constitución del dueño)

- Regla 0: quien desarrolla actúa con autonomía dentro del alcance. Ninguna entrega llega al dueño sin estar hecha, probada por la UI real con evidencia y comprobada contra lo pedido.
- Frenos del dueño: desplegar a producción, y gastar fuera del pool de pruebas o con alcance nuevo.
- Pruebas reales con gasto: autorizadas dentro del pool de créditos de prueba del proyecto Google Cloud de pruebas. Se para ante una alerta o con saldo bajo.
- Incrementos pequeños, controlados y verificados antes de seguir. Sin bucles de corrección: si un arreglo no converge, se para y se investiga la causa.
- Aprobación visual previa del dueño para cualquier cambio de lo que se ve. Lo aprobado se queda vivo: no se apaga ni se sustituye sin su OK.
- Antes de diseñar o cambiar algo de Google ADK, Gemini/Live, Vertex AI, google-genai, Drive, OAuth o Google Cloud, se pide al dueño la revisión técnica Google AI (su «Consultor Google AI»); sin veredicto APROBADO no se implementa.
- Foco actual: que los agentes funcionen en todos los servicios de Uonify, y que el motor de creación de vídeo y la postproducción ArtCraft funcionen de forma profesional.

### 10. Comprobaciones de cada PR

1. `python scripts/validate_structure.py` en un clon limpio, sin `node_modules` ni builds: sin errores nuevos. Es orientativo y no se hace obligatorio (`AGENTS.md:36`).
2. `git diff --check origin/dev...HEAD` limpio, y las pruebas del área tocada que indique el README de su carpeta.
3. Límite de 500 líneas, que ninguna CI comprueba (`scripts/validate_phase5.py` no está en ningún workflow). Desde la raíz del repo, solo pueden salir ficheros de la lista cerrada añadidos como copia exacta; no cuentan los binarios ni los ficheros de bloqueo generados.

   ```bash
   git diff --name-only --diff-filter=AMR origin/dev...HEAD | while read -r f; do [ -f "$f" ] && grep -Iq . "$f" && n=$(awk 'END{print NR}' "$f") && [ "$n" -gt 500 ] && echo "$n $f"; done
   ```

4. Escaneo de secretos de la sección 8, revisado. Lo que llega como copia de DEV tiene el mismo sha256 que el original y, si el PR cambia este bloque, su sha256 coincide en los 4 README (sección 11).
5. Tras fusionar, el `gh run list` de la sección 6 muestra solo lo previsto, en verde. Si algo falla, se para y se investiga.

### 11. Numeración, nombres, idioma y documentos comunes

- «Nosotros somos 0». Los hijos van correlativos (0.1, 0.2…; dentro, 0.2.1, 0.2.2…) y no se renumeran (`docs/FOLDER_STANDARD.md:9`); el 0.1 es del equipo y lo nuestro empieza en 0.2. Carpetas en inglés y kebab-case, con el número delante (`0.2-app`); README, commits y PR en español de España.
- Cada carpeta numerada existe igual en las 4 capas, con su README (responsabilidad, estado, dependencias y propietario, `AGENTS.md:18`); en infrastructure, además, con `resources.yml`, que vacío es una reserva excluida del despliegue (`docs/FOLDER_STANDARD.md:11`). Se crea cuando el dueño la decide o cuando entra su código, y entonces nace a la vez en las 4 capas: donde aún no hay código, solo con su README (`docs/FOLDER_STANDARD.md:13`; en infrastructure, también con `resources.yml` vacío). Nunca se crea por adelantado.
- Las carpetas técnicas (`app/`, `migrations/`…) no llevan número, nunca empiezan por un dígito ni se llaman `screens`: el validador las trataría como módulos.
- Cada carpeta numerada se da de alta en `docs/MODULE_REGISTRY.md`. Ese registro y los demás documentos que son copia idéntica en los 3 repos (`PROJECT.md` y los de `docs/` con el mismo sha256 en los tres, como `FRONTEND_ARCHITECTURE.md` o `UX_UI_STANDARD.md`) se cambian primero en platform y se copian idénticos a los otros dos. Después se compara el SHA-256, y los 3 PR se fusionan el mismo día. `AGENTS.md`, `CONTRIBUTING.md`, `START_HERE.md`, el `README.md` de la raíz y el resto de `docs/` son propios de cada repo y no se copian.
- Este bloque se cambia igual, en los 4 README a la vez. Comprobación en cada uno: `awk '/uonify-reglas-comunes:[s]tart/,/uonify-reglas-comunes:[e]nd/' README.md | shasum -a 256` (o `sha256sum`).

### 12. Roadmap y estado

- El roadmap vive fuera de los repos (D7): lo lleva el dueño y se pinta en el chat en cada hito. No se sube a git.
- Cada README lleva solo reglas y el estado verificable de su carpeta: qué hay, con qué evidencia (commit, sha256 o ejecución de workflow) y qué falta, sin inflarlo (`AGENTS.md:46`). Una carpeta o un README no acreditan implementación.
<!-- uonify-reglas-comunes:end -->

## Esta capa: database

Lo común (dónde vive Uonify, qué lanza cada fusión y qué no se toca) está en las Reglas comunes; aquí va solo lo propio de database.

### Qué hay en `modules/0-uonify`

| Ruta | De quién | Estado |
| --- | --- | --- |
| `README.md` | Uonify | Reglas de la carpeta (este fichero) |
| `0.2-app/` | Uonify | Las 139 migraciones de la base propia (D4), en git desde `48bbbfa` (PR #4); ver su README |
| `screens/conversation/` y `screens/hello-world/` | Equipo | Solo README, sin datos propios. Solo existen en database: ni platform ni infrastructure tienen `0-uonify/screens`. No se tocan; qué hacer con ellas lo decide el dueño con el arquitecto |

### Uonify en el SQL compartido, hoy

- En `schema/`, `seeds/` y `tests/` no hay schema `uonify` ni tablas de Uonify. Solo hay referencias del equipo, que no cambian al renumerar (`docs/MODULE_RENUMBERING.md:76`): los módulos `uonify.core` y `video.creation` (`seeds/001_module_catalog.sql:4-5`) y el permiso `uonify.connections.manage` (`schema/006_shared_identity_permissions.sql:31`), que no se reutiliza para otros dominios (`docs/FOUNDATION_INTEGRATION.md:18`).
- Regla del equipo: PostgreSQL no guarda historial de conversaciones, mensajes, prompts, respuestas, audio ni contexto de Uonify (`documentation/onboarding-data-model.md:9`). `tests/onboarding_model_test.sql:102-110` falla si alguna tabla, en cualquier schema, se llama `uonify…` o si `auditoria.events` tiene columnas de contenido.

### Dos tipos de SQL de Uonify

1. **Para la RDS compartida** (`mastererp-dev-data`, us-west-1). Hoy no hay ninguno. Toca rutas que llegan a la RDS y ficheros del equipo, así que solo empieza con decisión del dueño (ver Reglas comunes, sección 7) y llega completo en un único PR del día:
   - `schema/NNN_uonify_<tema>.sql`, repetible, solo hacia delante y sin `DROP`, `TRUNCATE` ni borrados (`docs/IMPLEMENTATION_PATTERN.md:3-10`). NNN es el siguiente número global libre: el 08-11-2026, el último de `SCHEMA_FILES` era el 048 (`migrations/lambda/handler.py:72`). Se fija justo antes de fusionar, con la rama al día, porque el equipo añade números casi a diario.
   - Prueba en `tests/uonify_<tema>_test.sql`, de `BEGIN;` a `ROLLBACK;` (`handler.py:15-21`), con el rol `mastererp_app`: aislamiento por tenant, permisos y conflictos.
   - Alta en `SCHEMA_FILES` y `TEST_FILES` y un lote propio del migrador: un módulo como `migrations/lambda/sales_validation.py`, una opción en `batch` (`apply-dev-database.yml:10-14`) y su clasificación en `scripts/database_apply_required.py:19-22`. Son ficheros del equipo. Sin lote, el SQL viaja en el paquete pero no se aplica: hoy los lotes solo aplican la 045 (`handler.py:349`) y la 048 (`sales_validation.py:7`).
   - Tablas en el schema `uonify` (aún no existe), con `tenant_id`, RLS y `REVOKE` a `mastererp_app`; acceso solo por funciones `SECURITY DEFINER` con `search_path` fijo, que comprueban `plataforma.has_current_tenant_capability` y auditan en `auditoria.events` sin contenido (patrón: `schema/046_sales_order_command.sql:22-35` y `:130-132`). Nunca conversaciones. Ningún permiso nuevo sin decisión del dueño (`docs/FOUNDATION_INTEGRATION.md:18`).
   - Aplicación real: solo a mano (`workflow_dispatch`, `apply_model=true` y el lote de Uonify), tras un snapshot de la RDS (como en `docs/SALES_READ_UI.md:9`) y con OK del dueño. La RDS no lleva registro de migraciones (`docs/ADMINISTRATION_DEV.md:9`) y la prueba con ROLLBACK no revierte un esquema confirmado (`docs/DEVELOPMENT_STANDARD.md:27`): lo aplicado se queda.
2. **Para la base propia de Uonify**: solo en `0.2-app/migrations` (D4), que ningún pipeline ejecuta; reglas en su README. Nunca en `schema/`, en `migration/` (cargas offline del equipo) ni en la raíz `migrations/` (reservada, `migrations/README.md:1`).

### Qué ejecuta cada ruta de este repo

Resumen en Reglas comunes, sección 6. Detalle de esta capa:

| Ruta tocada en `dev` | Efecto real |
| --- | --- |
| `schema/**`, `seeds/**`, `tests/**` | `deploy-migrator` redespliega la Lambda `mastererp-dev-database-migrator` con el `handler.py` que haya en `dev`, aunque sea trabajo a medias del equipo. Después, `apply` valida el lote `customer` (045), o `sales` si cambian sus ficheros, con DDL y bloqueos sobre la RDS con datos reales, dentro de `BEGIN…ROLLBACK` (`apply-dev-database.yml:52-86`; `handler.py:355-371`). Un SQL nuestro sin lote ni siquiera se valida |
| `migrations/lambda/**`, `scripts/package_migrator.py` y los YAML del migrador | Solo el redespliegue del migrador, sin validación SQL (`scripts/database_apply_required.py:9`) |
| Lanzamiento manual con `apply_model=true` | Redespliegue del migrador y `COMMIT` en la RDS, en dos pasadas (`handler.py:374-384`; `sales_validation.py:92-103`). El workflow no usa entornos protegidos: GitHub no pide otra aprobación |
| `infrastructure/rds-dev-us-west-1.yaml` | ⚠ `deploy-dev-rds.yml` redespliega la RDS compartida: `DeletionPolicy` y `UpdateReplacePolicy` en `Delete`, `DeletionProtection: false` y copias de 1 día (`:53-54`, `:69` y `:72`). Un reemplazo borraría datos reales. No se toca nunca |
| `modules/**`, `docs/`, `documentation/`, `migration/` | Solo «Validate structure» |

Un PR de Uonify en este repo solo toca `modules/0-uonify/**` y, para dar de alta una carpeta, `docs/MODULE_REGISTRY.md` (ver Reglas comunes, sección 11); cualquier otra ruta, solo con decisión del dueño. Tras fusionar, el `gh run list` de la sección 6 solo muestra «Validate structure».
