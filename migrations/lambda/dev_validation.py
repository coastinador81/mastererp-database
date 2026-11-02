"""Privileged DEV-only bootstrap via the official migration Lambda, never HTTP.

Synthetic fixture provisioning and application password setup are separate from
the normal read-only application role. No secrets are accepted in event payloads.
"""
import json
import os
import re
from uuid import UUID, uuid5, NAMESPACE_URL

import boto3
from pg8000.native import literal

ISSUER = "https://cognito-idp.us-west-1.amazonaws.com/us-west-1_oCn3VipDO"
ACTORS = ("admin_a", "member_a", "admin_b", "no_spaces")


def _dev_guard(context):
    arn = getattr(context, "invoked_function_arn", "").split(":")
    if (os.environ.get("ENVIRONMENT") != "dev" or os.environ.get("DB_NAME") != "mastererp"
            or len(arn) < 7 or arn[3:7] != ["us-west-1", "277352717693", "function", "mastererp-dev-database-migrator"]):
        raise ValueError("DEV bootstrap guard rejected")


def configure(connection, event, context):
    _dev_guard(context)
    run = event.get("run", "")
    if not re.fullmatch(r"qa-identity-[0-9a-f]{12}", run) or event.get("issuer") != ISSUER:
        raise ValueError("Invalid QA manifest")
    actors = event.get("actors", {})
    if set(actors) != set(ACTORS):
        raise ValueError("Invalid QA actor set")
    for label, actor in actors.items():
        UUID(actor["id"])
        UUID(actor["sub"])
        if actor["email"] != f"{run}-{label.replace('_','-')}@example.invalid":
            raise ValueError("QA addresses must be synthetic and run-scoped")
    arn = event.get("application_secret_arn", "")
    if not arn.startswith("arn:aws:secretsmanager:us-west-1:277352717693:secret:mastererp/dev/database/application-"):
        raise ValueError("Invalid application secret reference")
    raw = boto3.client("secretsmanager").get_secret_value(SecretId=arn)
    credential = json.loads(raw["SecretString"])
    if credential.get("username") != "mastererp_app" or len(credential.get("password", "")) < 32:
        raise ValueError("Invalid application credential")
    connection.run("BEGIN")
    try:
        flags = connection.run("SELECT rolsuper,rolbypassrls,rolcreatedb,rolcreaterole FROM pg_roles WHERE rolname='mastererp_app'")
        if not flags or any(flags[0]):
            raise ValueError("Application role privileges are not minimal")
        # PostgreSQL utility statements cannot use protocol bind parameters here.
        # literal performs escaping; neither SQL text nor credential is logged.
        connection.run("ALTER ROLE mastererp_app LOGIN PASSWORD " + literal(credential["password"]))
        for label, actor in actors.items():
            connection.run("""INSERT INTO plataforma.users
                (id,email,display_name,status,identity_provider,external_identity_id)
                VALUES (:id,:email,:name,'active','cognito',:sub)""",
                id=actor["id"], email=actor["email"], name=f"{run} {label}", sub=actor["sub"])
            connection.run("INSERT INTO plataforma.external_identities(issuer,subject,user_id) VALUES(:issuer,:sub,:id)",
                           issuer=ISSUER, sub=actor["sub"], id=actor["id"])
        tenants = {}
        # Canonical tenant creation primitive, evaluated as the actual application role.
        connection.run("SET LOCAL ROLE mastererp_app")
        for suffix, owner in (("a", "admin_a"), ("b", "admin_b")):
            connection.run("SELECT set_config('app.current_user_id',:actor,true), set_config('app.current_tenant_id','',true)",
                           actor=actors[owner]["id"])
            code = run + "-" + suffix
            tenant = connection.run("""SELECT plataforma.create_tenant_with_owner(
                :code,:slug,:name,'individual',:owner,:key)""", code=code, slug=code,
                name=f"Tenant QA {suffix.upper()} {run}", owner=actors[owner]["id"], key=code)[0][0]
            connection.run("SELECT set_config('app.current_tenant_id',:tenant,true)", tenant=str(tenant))
            # Same draft -> active transition used by onboarding provisioning.
            activated = connection.run("UPDATE plataforma.tenants SET status='active' WHERE id=:id AND status='draft' RETURNING id", id=tenant)
            if len(activated) != 1:
                raise ValueError("QA tenant activation denied")
            connection.run("""INSERT INTO auditoria.events(tenant_id,actor_user_id,module_code,entity_type,entity_id,action,metadata)
                VALUES(:tenant,:actor,'1.1-tenant-onboarding','tenant',:tenant,'tenant.provisioned',:metadata::jsonb)""",
                tenant=tenant, actor=actors[owner]["id"], metadata=json.dumps({"qa_validation": run}))
            tenants[suffix] = str(tenant)
        connection.run("RESET ROLE")
        # No membership-assignment primitive exists; this is explicit admin QA provisioning.
        connection.run("""INSERT INTO plataforma.user_tenants(tenant_id,user_id,status,joined_at)
            VALUES(:tenant,:actor,'active',now())""", tenant=tenants["a"], actor=actors["member_a"]["id"])
        connection.run("COMMIT")
        return {"status": "succeeded", "run": run, "tenants": tenants,
                "users": {label: actor["id"] for label, actor in actors.items()},
                "application_role": "mastererp_app", "correlation_id": getattr(context,"aws_request_id","unknown")}
    except Exception as error:
        connection.run("ROLLBACK")
        data = error.args[0] if error.args and isinstance(error.args[0], dict) else {}
        raise RuntimeError("DEV validation bootstrap failed; sqlstate=" + data.get("C","unknown")) from None


def verify(connection, event, context):
    """Read-only verification of synthetic state and actual role; no arbitrary SQL."""
    _dev_guard(context)
    return {"status": "succeeded", "identity_tables": connection.run(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='plataforma' AND table_name IN ('external_identities','permissions','role_permissions')")[0][0],
        "application_role_flags": connection.run("SELECT rolsuper,rolbypassrls,rolcreatedb,rolcreaterole FROM pg_roles WHERE rolname='mastererp_app'")[0],
        "application_role_memberships": [row[0] for row in connection.run("""SELECT parent.rolname
            FROM pg_auth_members membership JOIN pg_roles parent ON parent.oid=membership.roleid
            JOIN pg_roles member ON member.oid=membership.member WHERE member.rolname='mastererp_app'""")],
        "correlation_id": getattr(context,"aws_request_id","unknown")}


def membership_state(connection, event, context):
    """Change only the dedicated QA admin-A membership for inactivity testing."""
    _dev_guard(context)
    run = event.get("run", "")
    if (os.environ.get("ENVIRONMENT") != "dev" or not re.fullmatch(r"qa-identity-[0-9a-f]{12}", run)
            or event.get("status") not in ("active", "inactive")):
        raise ValueError("Invalid QA membership request")
    connection.run("BEGIN")
    try:
        changed = connection.run("""UPDATE plataforma.user_tenants ut SET status=:status
            FROM plataforma.users u,plataforma.tenants t
            WHERE ut.user_id=u.id AND ut.tenant_id=t.id
            AND u.email=:email AND t.code=:code RETURNING ut.id""",
            status=event["status"], email=run+"-admin-a@example.invalid", code=run+"-a")
        if len(changed) != 1:
            raise ValueError("QA membership not uniquely identified")
        connection.run("COMMIT")
        return {"status": "succeeded", "membership_status": event["status"], "run": run}
    except Exception:
        connection.run("ROLLBACK")
        raise RuntimeError("QA membership operation failed") from None


def foundation_state(connection, event, context):
    """DEV-only fault injection limited to the existing identifiable QA fixtures.

    Caller must restore returned baseline in finally. No arbitrary tenant, actor,
    permission, SQL or secret is accepted. No production identity can match guard.
    """
    _dev_guard(context)
    run = event.get("run", "")
    case = event.get("case")
    label = event.get("actor_label", "admin_a")
    if label not in ("admin_a", "admin_b"):
        raise ValueError("Invalid QA actor label")
    suffix = label[-1]
    allowed = {"inspect", "baseline", "user_inactive", "tenant_inactive", "membership_inactive", "permission_denied", "module_disabled", "restore", "cleanup_session"}
    if not re.fullmatch(r"qa-identity-[0-9a-f]{12}", run) or case not in allowed:
        raise ValueError("Invalid QA foundation case")
    connection.run("BEGIN")
    try:
        rows = connection.run("""SELECT u.id,t.id,u.status,t.status,ut.status,m.id
          FROM plataforma.users u JOIN plataforma.user_tenants ut ON ut.user_id=u.id
          JOIN plataforma.tenants t ON t.id=ut.tenant_id CROSS JOIN plataforma.modules m
          WHERE u.email=:email AND t.code=:code AND m.code='uonify.core'""",
          email=run+'-admin-'+suffix+'@example.invalid',code=run+'-'+suffix)
        if len(rows)!=1:
            raise ValueError("QA state not uniquely identified")
        actor,tenant,user_status,tenant_status,member_status,module=rows[0]
        if case == 'cleanup_session':
            session_id=str(UUID(str(event.get('session_id',''))))
            nonce=str(UUID(str(event.get('nonce',''))))
            removed=connection.run("""DELETE FROM plataforma.onboarding_sessions
              WHERE id=:id AND initiated_by_user_id=:actor AND tenant_id IS NULL
              AND context->>'qa_validation'=:run AND context->>'qa_probe'=:nonce
              RETURNING id""",id=session_id,actor=actor,run=run,nonce=nonce)
            if len(removed)!=1:
                raise ValueError("QA session cleanup did not identify exactly one owned probe")
            connection.run("COMMIT")
            return {"status":"succeeded","case":case,"removed_own_probe":1}
        overrides = connection.run("SELECT permissions_override FROM plataforma.user_tenants WHERE user_id=:actor AND tenant_id=:tenant",actor=actor,tenant=tenant)[0][0]
        assignment = connection.run("SELECT status FROM plataforma.tenant_modules WHERE tenant_id=:tenant AND module_id=:module",tenant=tenant,module=module)
        baseline = {"user":user_status,"tenant":tenant_status,"membership":member_status,
                    "overrides":overrides,"module":assignment[0][0] if assignment else None}
        if case == 'inspect':
            connection.run("ROLLBACK")
            return {"status":"succeeded","case":case,"baseline":baseline,"run":run}
        target = event.get("baseline") if case=='restore' else {**baseline,"user":"active","tenant":"active","membership":"active","overrides":{},"module":"active"}
        if not isinstance(target,dict) or target.get('user') not in ('active','inactive') or target.get('tenant') not in ('draft','active','suspended','cancelled') or target.get('membership') not in ('active','inactive') or target.get('module') not in (None,'selected','provisioning','active','suspended','cancelled') or not isinstance(target.get('overrides'),dict):
            raise ValueError("Invalid QA restoration state")
        if case=='user_inactive': target['user']='inactive'
        if case=='tenant_inactive': target['tenant']='suspended'
        if case=='membership_inactive': target['membership']='inactive'
        if case=='permission_denied': target['overrides']={'uonify.connections.manage':False}
        if case=='module_disabled': target['module']='suspended'
        connection.run("UPDATE plataforma.users SET status=:status WHERE id=:id",status=target['user'],id=actor)
        connection.run("UPDATE plataforma.tenants SET status=:status WHERE id=:id",status=target['tenant'],id=tenant)
        connection.run("UPDATE plataforma.user_tenants SET status=:status,permissions_override=:overrides::jsonb WHERE user_id=:actor AND tenant_id=:tenant",status=target['membership'],overrides=json.dumps(target['overrides']),actor=actor,tenant=tenant)
        if target['module'] is None:
            connection.run("DELETE FROM plataforma.tenant_modules WHERE tenant_id=:tenant AND module_id=:module",tenant=tenant,module=module)
        else:
            connection.run("""INSERT INTO plataforma.tenant_modules(tenant_id,module_id,status)
              VALUES(:tenant,:module,:status) ON CONFLICT(tenant_id,module_id) DO UPDATE SET status=excluded.status""",tenant=tenant,module=module,status=target['module'])
        connection.run("COMMIT")
        return {"status":"succeeded","case":case,"baseline":baseline,"run":run}
    except Exception as error:
        connection.run("ROLLBACK")
        data=error.args[0] if error.args and isinstance(error.args[0],dict) else {}
        raise RuntimeError("QA foundation state failed; sqlstate="+data.get('C','unknown')) from None


def inspect_foundation(connection,event,context):
    """Read-only catalog evidence, hashes and integrity counts; no customer rows."""
    _dev_guard(context)
    connection.run("BEGIN READ ONLY")
    try:
        functions=connection.run("""SELECT n.nspname||'.'||p.proname,
          encode(sha256(convert_to(p.prosrc,'UTF8')),'hex'),p.prosecdef,
          p.proconfig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname IN ('plataforma','organizacion') AND p.proname IN
          ('resolve_external_identity','has_current_tenant_permission','list_current_user_spaces',
           'has_current_tenant_capability','create_tenant_with_owner','register_company_once')
          ORDER BY 1""")
        ledgers=connection.run("""SELECT table_schema||'.'||table_name FROM information_schema.tables
          WHERE table_schema NOT IN ('pg_catalog','information_schema') AND
          (table_name ILIKE '%migration%' OR table_name IN
           ('schema_version','schema_migrations','flyway_schema_history','alembic_version','databasechangelog')) ORDER BY 1""")
        constraints=connection.run("""SELECT conname,convalidated FROM pg_constraint
          WHERE conname='branches_tenant_company_fk' AND conrelid='organizacion.branches'::regclass""")
        inconsistent=connection.run("""SELECT count(*) FROM organizacion.branches b
          WHERE NOT EXISTS(SELECT 1 FROM organizacion.companies c WHERE c.id=b.company_id AND c.tenant_id=b.tenant_id)""")[0][0]
        legacy=connection.run("SELECT count(*) FROM plataforma.idempotency_keys WHERE request_fingerprint IS NULL")[0][0]
        return {"status":"succeeded","functions":[{"name":r[0],"body_sha256":r[1],"security_definer":r[2],"config":r[3]} for r in functions],
                "migration_ledgers_detected":[r[0] for r in ledgers],"constraints":[{"name":r[0],"validated":r[1]} for r in constraints],
                "inconsistent_branch_links":inconsistent,"legacy_unfingerprinted_keys":legacy}
    finally:
        connection.run("ROLLBACK")


def dual_tenant(connection,event,context):
    """Temporary QA-only second membership. Never changes a pre-existing row."""
    _dev_guard(context)
    run=event.get('run','');action=event.get('operation')
    if not re.fullmatch(r'qa-identity-[0-9a-f]{12}',run) or action not in ('prepare','allow','deny','cleanup'):
        raise ValueError('Invalid dual-tenant QA request')
    nonce=str(UUID(str(event.get('nonce',''))))
    membership=str(uuid5(NAMESPACE_URL,run+':dual-tenant-qa:'+nonce))
    connection.run('BEGIN')
    try:
        connection.run('SELECT pg_advisory_xact_lock(hashtextextended(:scope,0))',scope=run+':dual-tenant-qa')
        rows=connection.run("""SELECT a.id,t.id,r.id FROM plataforma.users a,
          plataforma.users b,plataforma.tenants t,plataforma.roles r
          WHERE a.email=:a AND b.email=:b AND t.code=:code
          AND a.status='active' AND b.status='active' AND t.status='active'
          AND r.code='tenant.owner' AND EXISTS(SELECT 1 FROM plataforma.user_tenants ut
          WHERE ut.user_id=b.id AND ut.tenant_id=t.id AND ut.status='active' AND ut.role_id=r.id)""",
          a=run+'-admin-a@example.invalid',b=run+'-admin-b@example.invalid',code=run+'-b')
        if len(rows)!=1:raise ValueError('QA fixtures not uniquely identified')
        actor,tenant,role=rows[0]
        if action=='prepare':
            if connection.run('SELECT id FROM plataforma.user_tenants WHERE user_id=:actor AND tenant_id=:tenant',actor=actor,tenant=tenant):
                raise ValueError('Existing second membership must be preserved')
            membership=str(connection.run("""INSERT INTO plataforma.user_tenants(id,user_id,tenant_id,role_id,status,permissions_override,joined_at)
                VALUES(:id,:actor,:tenant,:role,'active','{"uonify.connections.manage":false}'::jsonb,now()) RETURNING id""",
                id=membership,actor=actor,tenant=tenant,role=role)[0][0])
        elif action=='cleanup':
            rows=connection.run('DELETE FROM plataforma.user_tenants WHERE id=:id AND user_id=:actor AND tenant_id=:tenant AND role_id=:role RETURNING id',id=membership,actor=actor,tenant=tenant,role=role)
            if len(rows)!=1:raise ValueError('QA membership not uniquely identified')
        else:
            overrides={} if action=='allow' else {'uonify.connections.manage':False}
            rows=connection.run('UPDATE plataforma.user_tenants SET permissions_override=:overrides::jsonb WHERE id=:id AND user_id=:actor AND tenant_id=:tenant AND role_id=:role RETURNING id',overrides=json.dumps(overrides),id=membership,actor=actor,tenant=tenant,role=role)
            if len(rows)!=1:raise ValueError('QA membership not uniquely identified')
        connection.run('COMMIT')
        return {'status':'succeeded','operation':action,'membership_id':membership}
    except Exception as error:
        connection.run('ROLLBACK')
        details=error.args[0] if error.args and isinstance(error.args[0],dict) else {}
        raise RuntimeError('Dual-tenant QA failed; sqlstate='+details.get('C','unknown')) from None
