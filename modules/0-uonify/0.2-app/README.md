# Aplicación Uonify

Antes de trabajar aquí, leer el [README de `0-uonify`](../README.md): sus «Reglas comunes de Uonify (0)» y su sección «Esta capa: database» valen también para esta carpeta. Este README solo añade lo propio de `0.2-app` en database.

Objetivo específico: guardar en git, como copia exacta, las migraciones de la base de datos propia de la app de Uonify que corre en https://dev.uonify.com, y las reglas para cambiarlas.

Responsabilidad: las migraciones SQL del PostgreSQL propio de Uonify en DEV. No es SQL de MasterERP: no va a la RDS compartida ni pasa por el migrador del equipo.
Estado: las 139 migraciones de la base propia están en `migrations/` desde `48bbbfa` (PR #4, fusionado en `1236254`, 08-11-2026), como copia exacta de `/app/migrations` de la imagen de la API de DEV. Fusionar aquí no ejecuta nada.

## Contrato y estado de esta capa

Código: 0.2. Nombre/ruta: `0-uonify/0.2-app`. Propietario funcional: el dueño de Uonify (Product Owner). Propietario de los datos: Uonify; su base propia no comparte tablas con MasterERP.

Capa: datos. Dependencias: la API de Uonify en platform (`backend/modules/0-uonify/0.2-app`), que aplica estas migraciones al arrancar, y el host de DEV en infrastructure (`modules/0-uonify/0.2-app`), donde corre su PostgreSQL. Exclusiones: `schema/`, `seeds/`, `tests/`, el migrador (`migrations/lambda/`) y la RDS compartida. APIs/eventos/MCP: ninguno en esta capa.

Estado verificable: 139 de 139 en git, con la misma huella que la imagen (bloque de «Qué hay»; comprobado en `dev` `2d062f2`, 08-11-2026). Una carpeta o un README no acreditan implementación.

Validaciones: ver Reglas comunes, sección 10, y la prueba del punto 4 de «Cambiar o añadir una migración».

## Por qué aquí y no en `schema/` (D4)

D4 (08-11-2026) la decidió el CEO al aplicar la regla del dueño «database para la base de datos»: las migraciones de la base propia viven en `0.2-app/migrations`, fuera de `schema/` y del uso documental que `docs/HOW_TO_BUILD_A_MODULE.md:42` da a `modules/`. Según `AGENTS.md:32`, como excepción necesita la confirmación expresa del dueño con este alcance (solo estas migraciones); hasta tenerla, figura en Pendientes. El SQL de MasterERP sigue en `schema/` (`docs/IMPLEMENTATION_PATTERN.md:3-5`).

- Ningún pipeline las ejecuta: `modules/**` no está en los `paths` de `apply-dev-database.yml:15-24`, y el migrador solo empaqueta lo que fija `scripts/package_migrator.py:12-30` (su manifiesto, módulos fijos y `tests/administration/*.sql`), nada de `modules/`. En `schema/`, `seeds/` o `tests/`, cada fusión redesplegaría el migrador y validaría contra la RDS compartida.
- Las aplica la propia API al arrancar, en su PostgreSQL de la EC2 de DEV (`app/main.py:68-69` y `app/database.py:14-27` de la imagen; detalle en «Cómo se aplican»).
- Siguen un modelo que la RDS compartida no admite: unas 165 tablas en `public`, sin `tenant_id` ni RLS; identidad propia (`users.google_subject`, en `001_identity.sql`); roles propios `uonify_*`, y contenido de conversación (`010_onboarding_completion.sql:6-7`, `075_uony_live_turns.sql:9`), que el equipo prohíbe en PostgreSQL (`documentation/onboarding-data-model.md:9`).

## Qué hay

`migrations/`: copia exacta de `/app/migrations` de la imagen de la API que corre hoy en DEV (`uonify-dev-api:devorigin-20261107`, id `sha256:7e3743d0cbc9…`, repositorio ECR `uonify-dev/api`). La imagen de `clips-worker` lleva la misma carpeta.

| Dato | Valor |
| --- | --- |
| Ficheros | 139 `.sql`, de `001_identity.sql` a `142_creative_clip_drive_deliveries.sql` |
| Numeración | `083` aparece dos veces (`083_backfill_live_access_reply.sql` y `083_uony_live_creative_handoff.sql`); no existen 127, 131, 135 ni 136 |
| Más de 500 líneas | 7, en la lista de excepción de abajo |
| Huella del conjunto | La del bloque siguiente, calculada el 08-11-2026 sobre el `/app` extraído de la imagen (con `sha256sum` sale igual) |

```bash
cd modules/0-uonify/0.2-app/migrations && shasum -a 256 *.sql | shasum -a 256
# de2bd0f29f078d04717257d5c694f852c94407ab06db547a39414c58c1fed4b5  -
```

- La única fuente es la imagen desplegada, no un árbol de trabajo: el árbol local anterior tiene en 131, 135, 136 y 137 migraciones que no son las de DEV.
- El conversation-worker (línea CONV, `uonify-dev-conv:devorigin-20261107`) lleva solo 108 de las 139, con el mismo sha256. Se unificará con la API en un paso propio.

## Cómo se aplican

Rutas del backend en platform (`backend/modules/0-uonify/0.2-app`, en git desde `7608ad5`), iguales a las de la imagen.

- La API ejecuta `database.migrate()` al arrancar (`app/main.py:68-69`), y también los workers (`app/run_conversation_worker.py:27`, `app/run_material_worker.py:33`, `app/billing_worker.py:66` y `app/run_clips_only_worker.py:44`).
- `migrate()` (`app/database.py:14-27`) toma un bloqueo de PostgreSQL, crea si falta `schema_migrations (name, checksum)`, recorre `/app/migrations/*.sql` (la carpeta `migrations/` junto a `app/`, `app/database.py:18`) por orden de nombre y aplica una sola vez cada fichero que falte, guardando su sha256. Todo va en una transacción: si una falla, no queda aplicada ninguna de esa vuelta.
- Si cambia una ya aplicada, falla con «Una migración aplicada ha cambiado» y la API no arranca (`app/database.py:23-24`).
- Destino: el PostgreSQL 17 propio de la EC2 de DEV (servicio `db` de Docker Compose, base `uonify`, datos en el volumen cifrado del host), elegido por `PGHOST` (`app/settings.py:176`). Fusionar en git no aplica nada: una migración llega a la base cuando arranca en DEV una imagen que la contiene.

⚠ Nunca contra la RDS compartida. Si `PGHOST` apuntara a ella, `migrate()` crearía allí `schema_migrations`, los roles `uonify_*` y todas estas tablas en `public`, conversaciones incluidas.

## Datos de DEV y copia previa

La base de DEV arrancó vacía (decisión del dueño del 07-11-2026) y ya guarda datos del dueño: su usuario y su periodo de prueba. Antes de cualquier cambio (imagen con migraciones nuevas, restauración o mudanza), copia de la base y comprobación:

- El código del host instala la copia nocturna `uonify-pg-backup` (02:15 UTC). Sube a S3, cifrados con la clave KMS del stack de DEV, `.roles.sql` (roles sin contraseñas), `.dump` (`pg_dump -Fc` de la base `uonify`) y, el último, `.manifest` con sus sha256. Una copia sin `.manifest` no vale.
- No basta la nocturna, porque hoy no hay alarma si falla. Antes de aplicar, copia a demanda en la EC2, por SSM: `sudo systemctl start uonify-pg-backup.service`, y comprobar su `.manifest`. Antes de desplegar una imagen, además, snapshot del volumen de datos desde fuera del host (`aws ec2 create-snapshot`; el rol del host no puede), como pide el runbook del stack.
- Restaurar sustituye datos del dueño: solo con su OK. Resumen del script: comprobar los sha256 del `.manifest`, crear solo los roles `uonify_craft_*` que use el volcado y lanzar `pg_restore -d uonify` sin `--no-owner` ni `--no-privileges`.
- Ningún volcado, copia ni dato real entra en git (`.gitignore` de esta carpeta; ver Reglas comunes, sección 8).

El código del host, con la copia nocturna, está en infrastructure, en `modules/0-uonify/0.2-app/host/bootstrap/files/` (`uonify-pg-backup.sh`, `.service` y `.timer`), desde `9595886`.

## Lista de excepción de 500 líneas (D3) de esta capa

Migraciones ya aplicadas en DEV que llegaron como copia exacta (lista cerrada; ver Reglas comunes, sección 3). No se editan ni se parten: editada, cambia su checksum y la API no arranca; partida, los trozos son ficheros nuevos y se aplicarían otra vez. Una corrección es una migración nueva de 500 líneas como máximo.

| Migración | Líneas | sha256 (12 primeros) |
| --- | --- | --- |
| `116_creative_craft_materialization_intents.sql` | 3254 | `4aa6f14b0fd9` |
| `114_creative_craft_physical_transition_authority.sql` | 2439 | `dc1617710c3a` |
| `120_creative_craft_legacy_input_cohort.sql` | 1500 | `5d16720f16c0` |
| `119_creative_craft_input_consumption_authority.sql` | 1223 | `5fd4c2d966ed` |
| `118_creative_craft_input_mint_authority.sql` | 984 | `9967cee66e3c` |
| `113_creative_craft_transition_multi_installation.sql` | 612 | `f6123e357887` |
| `117_creative_craft_orchestrator_v2.sql` | 594 | `b228aeaba735` |

## Cambiar o añadir una migración

1. Una migración aplicada no se edita, renombra, borra ni reordena: su nombre es la clave de `schema_migrations` y su sha256 se comprueba en cada arranque. Corregir es añadir una nueva.
2. Número: el siguiente por encima del mayor; las nuevas empiezan en la 143. Nunca se rellenan huecos (127, 131, 135, 136) ni se repite un número: una base nueva las aplicaría en otro orden que DEV.
3. Nombre `NNN_<tema>.sql` en snake_case, como las existentes; un tema por fichero; 500 líneas como máximo; sin secretos, UUID ni datos reales.
4. Prueba antes del PR: aplicar la cadena completa, de la 001 a la nueva, con el mismo `Database.migrate()` de la API sobre un PostgreSQL 17 desechable y vacío. Aplicar los ficheros con `psql` no equivale: `migrate()` los ejecuta todos en una sola transacción, y una migración que solo funcione fichero a fichero impediría arrancar la API en DEV. DEV usa `postgres:17-alpine`, fijada por digest, con usuario y base `uonify` (infrastructure, `modules/0-uonify/0.2-app/host/runtime/compose.yaml:135-143`). Desde el clon de platform, en `backend/modules/0-uonify/0.2-app`, con las dependencias de `requirements.lock` instaladas y `DB_CLON` como ruta absoluta del clon de database:

   ```bash
   docker run --rm -d --name uonify-pg-prueba -e POSTGRES_USER=uonify -e POSTGRES_DB=uonify -e POSTGRES_HOST_AUTH_METHOD=trust -p 127.0.0.1:55432:5432 postgres:17-alpine
   until docker exec uonify-pg-prueba pg_isready -q -h 127.0.0.1 -U uonify; do sleep 1; done
   ln -s "$DB_CLON/modules/0-uonify/0.2-app/migrations" migrations   # enlace temporal: no se sube
   python -c "from app.database import Database; Database({'host': '127.0.0.1', 'port': 55432, 'dbname': 'uonify', 'user': 'uonify'}).migrate()"
   rm migrations; docker stop uonify-pg-prueba
   ```

   Por último, las pruebas que indique el README de `backend/modules/0-uonify/0.2-app` en platform.
5. El SQL va en este repo y el código que lo usa, en platform: los dos PR se fusionan el mismo día.
6. Llega a DEV cuando arranca una imagen que la contiene: antes, la copia de la sección «Datos de DEV y copia previa».

## Pendientes

- Confirmación expresa del dueño de D4 como excepción (`AGENTS.md:32`), con el alcance de «Por qué aquí y no en `schema/`».
- Decidir cómo recibe estas migraciones el build de la imagen de la API, que las necesita en `/app/migrations` (`app/database.py:18`): leerlas de este repo privado desde un workflow de platform requiere una credencial guardada como secreto, y los secretos solo los configura la cuenta `eticayservicios`.
- Unificar la línea CONV (108 migraciones) con la de la API.
- Alarma de copia fallida en el host (infraestructura).
- D6 (ver Reglas comunes, sección 3): si DEV se alinea con la RDS compartida, el historial de conversación de esta base no podrá ir allí (`documentation/onboarding-data-model.md:9`).
