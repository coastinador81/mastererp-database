"""Explicit DEV owner membership provisioning; no role grants or other tenants changed."""
import json
from uuid import UUID, uuid4
from dev_validation import ISSUER, _dev_guard
from uonify_access import EMAIL, _identity


def provision(connection, event, context):
    _dev_guard(context)
    if (event.get('tenant_code') != 'tumandaito' or event.get('issuer') != ISSUER
            or event.get('role_code') != 'tenant.owner' or event.get('full_catalog_access') is not True
            or event.get('operation') not in ('inspect', 'apply')):
        raise ValueError('Explicit Tumandaito owner contract required')
    subject = str(UUID(str(event.get('subject', ''))))
    approver = str(UUID(str(event.get('approved_by_subject', ''))))
    email = str(event.get('email', '')).lower()
    if not EMAIL.fullmatch(email) or email.startswith('qa-') or email.endswith('.invalid'):
        raise ValueError('Existing real Cognito identity required')
    phase, correlation = 'scope', str(uuid4())
    connection.run('BEGIN READ ONLY' if event['operation'] == 'inspect' else 'BEGIN')
    try:
        connection.run("SELECT pg_advisory_xact_lock(hashtextextended('mastererp-dev:business:tumandaito',0))")
        tenants = connection.run("SELECT id FROM plataforma.tenants WHERE code='tumandaito' AND slug='tumandaito' AND status='active' AND deleted_at IS NULL")
        roles = connection.run("SELECT id FROM plataforma.roles WHERE code='tenant.owner'")
        if len(tenants) != 1 or len(roles) != 1:
            raise ValueError('Unique active tenant and existing owner role required')
        tenant, role = str(tenants[0][0]), str(roles[0][0])
        approval = connection.run("""SELECT e.user_id FROM plataforma.external_identities e
            JOIN plataforma.users u ON u.id=e.user_id
            JOIN plataforma.user_tenants ut ON ut.user_id=u.id AND ut.tenant_id=:tenant
            WHERE e.issuer=:issuer AND e.subject=:subject AND e.status='active'
            AND u.status='active' AND ut.status='active' AND ut.role_id=:role""",
            tenant=tenant, issuer=ISSUER, subject=approver, role=role)
        if len(approval) != 1 or subject == approver:
            raise ValueError('Existing active owner approval required')
        phase = 'identity'
        actor, identity = _identity(connection, subject, email)
        rows = connection.run("SELECT id,role_id,status,permissions_override FROM plataforma.user_tenants WHERE tenant_id=:tenant AND user_id=:actor",
                              tenant=tenant, actor=actor)
        role_permissions = {r[0] for r in connection.run('SELECT permission_code FROM plataforma.role_permissions WHERE role_id=:role', role=role)}
        declared = {r[0] for r in connection.run('SELECT code FROM plataforma.permissions')}
        overrides = {code: True for code in sorted(declared - role_permissions)}
        if rows and (len(rows) != 1 or [str(rows[0][1]), rows[0][2], rows[0][3]] != [role, 'active', overrides]):
            raise ValueError('Existing membership differs; preserved unchanged')
        expected = sorted(declared)
        if not role_permissions:
            raise ValueError('Owner role has no permissions; no grants are added here')
        changed = False
        if event['operation'] == 'apply' and not rows:
            phase = 'provision'
            if identity == 'absent':
                connection.run("""INSERT INTO plataforma.users(id,email,display_name,status,identity_provider,external_identity_id)
                    VALUES(:actor,CAST(:email AS citext),'Tenant administrator','active','cognito',:subject)""",
                    actor=actor, email=email, subject=subject)
                connection.run("INSERT INTO plataforma.external_identities(issuer,subject,user_id,status) VALUES(:issuer,:subject,:actor,'active')",
                               issuer=ISSUER, subject=subject, actor=actor)
            member = str(connection.run("""INSERT INTO plataforma.user_tenants(tenant_id,user_id,role_id,status,permissions_override,joined_at)
                VALUES(:tenant,:actor,:role,'active',CAST(:overrides AS jsonb),transaction_timestamp()) RETURNING id""",
                tenant=tenant, actor=actor, role=role, overrides=json.dumps(overrides))[0][0])
            changed = True
        verified = False
        permissions, modules = [], []
        if rows or changed:
            phase = 'verification'
            connection.run('SET LOCAL ROLE mastererp_app')
            if connection.run('SELECT current_user')[0][0] != 'mastererp_app':
                raise ValueError('Application role required')
            connection.run("""SELECT set_config('app.current_user_id',:actor,true),set_config('app.current_tenant_id',:tenant,true),
                set_config('app.correlation_id',:correlation,true)""", actor=actor, tenant=tenant, correlation=correlation)
            spaces = {str(r[0]) for r in connection.run('SELECT tenant_id FROM plataforma.list_current_user_spaces()')}
            owns = connection.run('SELECT plataforma.user_owns_current_tenant(:tenant)', tenant=tenant)[0][0]
            frontend = connection.run('SELECT plataforma.current_frontend_context()')[0][0]
            permissions, modules = sorted(frontend['permissions']), sorted(frontend['modules'])
            if tenant not in spaces or owns is not True or permissions != expected:
                raise ValueError('Effective owner permissions verification failed')
            verified = True
            connection.run('RESET ROLE')
        if changed:
            phase = 'audit'
            connection.run("""INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,correlation_id,metadata)
                VALUES(:tenant,:approver,'1.1-tenant-onboarding','membership',:member,'dev.tenant.owner.provisioned',:correlation,
                jsonb_build_object('resultado','succeeded','role','tenant.owner','target_user_id',CAST(:actor AS text),'explicit_owner_approval',true))""",
                tenant=tenant, approver=str(approval[0][0]), member=member, correlation=correlation, actor=actor)
            connection.run('SET CONSTRAINTS ALL IMMEDIATE')
        connection.run('COMMIT' if changed else 'ROLLBACK')
        return {'status': 'succeeded', 'operation': event['operation'], 'changed': changed,
                'identity': identity, 'membership': 'active' if rows or changed else 'absent',
                'tenant_code': 'tumandaito', 'role': 'tenant.owner', 'verified_as': 'mastererp_app' if verified else None,
                'permission_count': len(permissions), 'role_permission_count': len(role_permissions), 'modules': modules,
                'individual_grants': sorted(overrides),
                'correlation_id': correlation}
    except Exception as error:
        connection.run('ROLLBACK')
        if isinstance(error, ValueError):
            raise
        details = error.args[0] if error.args and isinstance(error.args[0], dict) else {}
        raise RuntimeError('Owner access failed; phase=' + phase + '; sqlstate=' + details.get('C', 'unknown')) from None
