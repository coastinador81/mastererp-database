# Onboarding authorization — validado en RDS DEV

| Resource | Active owner in matching context | Non-admin member | Outsider / missing tenant |
| --- | --- | --- | --- |
| Tenant | Read, update configuration/status columns | Read only | No rows |
| Tenant modules / companies / branches | Read, insert, update | No rows (conservative) | No rows |
| Membership | Read in current tenant | Read in current tenant | No rows |
| Sessions/responses | Actor's own session, matching owned tenant | Only own unattached bootstrap session with no tenant context | No attached sessions |
| Users | Active actor only, read | Same | No other users |
| Roles / module / flow catalogue | Read only | Read only | Requires trusted authenticated backend |
| Audit | Member read, owner insert with matching actor | Read only | No rows |
| Idempotency | Actor + app.current_operation, read only | Same | No other actor/operation |
| Tenant creation | Controlled function, actor must equal owner, active user, no tenant context | Same bootstrap permission | Rejected without actor |

Backend must validate identity and membership before setting transaction-local app.current_user_id, app.current_tenant_id and app.current_operation; custom PostgreSQL settings are trusted backend assertions, not authentication. Never expose a SQL connection or arbitrary set_config to clients. Reset context through transaction rollback/commit when pooling. Use real mastererp_app credentials, never RDS admin for request handling.

create_tenant_with_owner retains its signature; clear tenant context for bootstrap and set new context after creation. Existing users must be provisioned through the identity service; direct app inserts/updates of users, roles, membership and catalogue are removed. Direct idempotency writes are removed: tenant.create caches internally; other operations need an authorized dedicated function before enabling their cache writes. Global primary key is retained: collisions across actors/operations are rejected, not reused.

004 removes blanket/default grants and checks creation authorization. 005 reapplies explicit grants and stricter policies on every migration run, before seeds/tests. Packaging already includes schema/*.sql. No table/data deletion and no new BYPASSRLS grant.

Validado en PostgreSQL RDS DEV mediante commit 454fec7 y ejecución 41310430235. Las comprobaciones SQL como mastererp_app pasaron, incluida reaplicación. No acredita funcionamiento completo del backend. Mantener credenciales de aplicación y contexto transaccional de confianza; ver dev-authorization-validation.md para recuperación.
