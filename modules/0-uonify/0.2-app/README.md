# Aplicación Uonify

Objetivo específico: esquema de la base de datos propia de la aplicación de Uonify que corre en https://dev.uonify.com.

Responsabilidad: migraciones SQL del PostgreSQL propio de Uonify, que no es la RDS compartida de MasterERP.
Estado: las 139 migraciones (001 a 142) están copiadas tal cual del `/app/migrations` de la imagen API que corre en DEV (08-11-2026). Fusionar en esta carpeta no ejecuta nada.

Antes de trabajar aquí, lee el README de [0-uonify](../README.md).

## Contrato y estado de esta capa

Código: 0.2. Nombre/ruta: `0-uonify/0.2-app`. Propietario funcional: Uonify; las decisiones las toma el Product Owner de Uonify. Capa: datos. Dependencias: backend de `mastererp-platform/backend/modules/0-uonify/0.2-app`. Exclusiones: la RDS compartida y sus schemas.

Las migraciones están fuera de `schema/` a propósito. Ningún pipeline de este repo vigila `modules/`, así que no se ejecutan desde aquí ni van nunca a la RDS compartida. Las aplica la propia API al arrancar, sobre su PostgreSQL de la EC2 de DEV. En mastererp-platform, `backend/modules/0-uonify/0.2-app/app/main.py:69` llama a `database.migrate()` (`app/database.py:14-27`), que recorre en orden los `*.sql` de `/app/migrations` de la imagen y guarda el nombre y el sha256 de cada uno en `schema_migrations`. Por eso, al construir la imagen, estas migraciones tienen que ir a `/app/migrations`.

## Reglas de esta carpeta

- Una migración ya aplicada no se edita nunca. Su checksum está guardado y, si cambia, la API no arranca.
- Las nuevas son correlativas y empiezan en la 143. Cada una con 500 líneas como máximo.
- Antes de aplicar cualquier migración en DEV, se hace una copia de la base. La base de DEV ya contiene datos.
- No se copian aquí datos, volcados ni secretos.
- Límite de 500 líneas: la excepción del Product Owner (08-11-2026) cubre solo estas 7 migraciones ya aplicadas, que no se pueden partir porque se aplicaron tal cual:
  - `116_creative_craft_materialization_intents.sql` (3.254), `114_creative_craft_physical_transition_authority.sql` (2.439), `120_creative_craft_legacy_input_cohort.sql` (1.500), `119_creative_craft_input_consumption_authority.sql` (1.223), `118_creative_craft_input_mint_authority.sql` (984), `113_creative_craft_transition_multi_installation.sql` (612) y `117_creative_craft_orchestrator_v2.sql` (594).
- El SQL de Uonify para la RDS compartida no va aquí: sigue el patrón del equipo en `schema/`. Ver el README de 0-uonify.
