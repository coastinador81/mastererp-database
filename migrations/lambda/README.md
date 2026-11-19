# DEV database migrator

Esta Lambda se ejecuta dentro de la VPC de la RDS y solo inicia una conexión dentro de `lambda_handler` tras una invocación explícita. Lee `DB_SECRET_ARN`, obtiene las credenciales del secreto administrado por RDS, usa SSL y un advisory lock PostgreSQL. No registra credenciales, endpoints, SQL ni contenido de Uonify.

## Miembro de Finanzas de solo lectura en Tumandaito (`provision_uonify_finance_member`)

Solo DEV. Decisión explícita del Product Owner (10-11-2026): una identidad Cognito ya creada en el pool de DEV lee Finanzas (Clientes, Proveedores, Compras y Ventas) en el espacio de pruebas Tumandaito. Código en `uonify_access.py`; se invoca únicamente mediante esta Lambda, nunca por HTTP, y `_dev_guard` exige `ENVIRONMENT=dev`, `DB_NAME=mastererp` y el ARN de `mastererp-dev-database-migrator` en us-west-1. El empaquetador `scripts/package_migrator.py` incluye el módulo.

Evento (sin datos reales en el código; correo y `sub` llegan en la invocación). Debe traer exactamente estos campos; cualquier otro, como el antiguo `role_code`, se rechaza:

```json
{"action": "provision_uonify_finance_member", "issuer": "<ISSUER de dev_validation.py>",
 "subject": "<sub Cognito, UUID canónico>", "email": "<correo de la cuenta Cognito>",
 "tenant_code": "tumandaito",
 "permissions": ["administration.parties.read", "administration.purchases.read", "administration.read"],
 "correlation_id": "<uuid>", "operation": "inspect | apply"}
```

- Acceso por lista de permitidos, sin rol: la pertenencia queda con `role_id` NULL (como `configure` en `dev_validation.py` y `party_validation.py`) y el override `{"administration.parties.read": true, "administration.purchases.read": true, "administration.read": true}`. Con rol NULL, `has_current_tenant_permission` (006) devuelve false para cualquier otro código. Ninguna concesión a un rol, presente o futura (por ejemplo, las escrituras previstas para `tenant.finance_admin`, 047), puede ampliar este acceso. Permisos efectivos: exactamente esas tres lecturas, sin escritura. Que aparezca un rol de Finanzas con nombre exigiría un rol propio de solo lectura creado por migración: decisión pendiente del Product Owner.
- Un único asiento: si en Tumandaito otra identidad ya tiene una pertenencia con este override o un evento `dev.finance.member.provisioned`, la acción se detiene sin escribir, también en `inspect`. Rechaza identidades QA sintéticas: correos `qa-*` o de dominio `.invalid`, y usuarios con nombre `qa-*`.
- `inspect`: transacción `READ ONLY`; no escribe y devuelve el estado.
- `apply`: una transacción con el mismo bloqueo consultivo que `bootstrap_tumandaito`. Reutiliza la identidad activa issuer+sub; si no existe, crea `plataforma.users` y `plataforma.external_identities` con id `uuid5(NAMESPACE_URL, ISSUER + "|" + sub)`. Nunca enlaza un usuario existente por coincidencia de correo. No hay ACL por empresa o sucursal (contrato 007): se exige `erp.finance` activo y empresas y sucursales activas del tenant. Antes de confirmar comprueba como `mastererp_app`, con el contexto del nuevo miembro, `list_current_user_spaces`, `current_frontend_context` y `has_current_tenant_capability` por empresa y, para `administration.read`, por sucursal. Registra `dev.finance.member.provisioned` en `auditoria.events` sin correo.
- Idempotente: reejecutar no escribe ni audita de nuevo (`changed: false`). Se detiene sin escribir (`ValueError`) si el espacio o el módulo no son los esperados, si la identidad está inactiva o tiene otro correo, si el correo pertenece a otro usuario, si la pertenencia existe con rol, estado u overrides distintos, si el asiento es de otra identidad o si los permisos efectivos difieren. `inspect` puede relanzarse en cualquier momento para comprobar los permisos efectivos exactos.
- Respuesta sin correos ni identificadores: `identity` y `membership` (`created`, `existing` o `absent`), `role` (siempre `null`), `module`, `companies`, `branches`, `space_visible`, `visible_companies`, `permissions` y `changed`.
- Nunca cambia la propiedad del espacio, roles, `role_permissions`, otras pertenencias, módulos del tenant, datos de negocio ni Cognito. Retirar el acceso o cambiar la identidad del asiento requiere una acción explícita aparte.

## Ordenes ficticias autorizadas de Tumandaito

Accion existente `seed_tumandaito_suppliers`, operaciones `inspect_orders` / `seed_orders`, mediante workflow manual separado. Reutiliza comandos de compras como mastererp_app y no aplica migraciones. Ver [procedimiento, idempotencia y recuperacion](../../documentation/tumandaito-order-samples.md).

## Administrador completo de Tumandaito DEV

La accion `provision_business_owner` incorpora, previa aprobacion explicita del propietario, una identidad Cognito real al rol existente `tenant.owner` exclusivamente dentro de Tumandaito. Usa issuer + sub, nunca enlaza por coincidencia de correo, y exige el sub de un propietario activo que autoriza. `inspect` es READ ONLY; `apply` crea solo usuario/identidad y pertenencia ausentes, comprueba permisos efectivos como mastererp_app y audita la aprobacion. Repetir devuelve changed=false. Una pertenencia existente con rol, estado u overrides diferentes se conserva y se rechaza.

Evento: action, operation (inspect/apply), tenant_code=tumandaito, role_code=tenant.owner, issuer (DEV), subject, email y approved_by_subject (propietario activo existente). Los datos personales se suministran al invocar, no se versionan. Solo us-west-1, cuenta 277352717693, migrador oficial y ENVIRONMENT=dev. No cambia el propietario original, otras pertenencias, permisos del rol compartido, Cognito, modulos contratados ni datos de negocio.

Se heredan los permisos actuales y futuros que se asignen al rol tenant.owner. No existe comodin universal: cada nueva capacidad debe declarar sus permisos y asignarlos al rol por el mecanismo oficial. Se mantienen las denegaciones, RLS y requisitos de modulo/tenant/empresa activos; no se habilitan modulos ni se otorga acceso a otros tenants, AWS o GitHub.

Publicacion: cambios solo del migrador/empaquetado/documentacion en dev -> workflow existente actualiza Lambda -> apply se omite por no cambiar schema/, seeds/ ni tests/. Esperar exito y verificar inspect antes de invocar apply por AWS CLI. No invocar apply_model ni reaplicar migraciones. Despues repetir apply e inspect para verificar idempotencia y persistencia. Un error revierte toda la transaccion. Retirar acceso requiere solicitud explicita y operacion acotada; revertir codigo no revierte una pertenencia confirmada. La contrasena temporal y la prueba de login corresponden al invitado; nunca se utilizan ni restablecen para validar sus permisos.
