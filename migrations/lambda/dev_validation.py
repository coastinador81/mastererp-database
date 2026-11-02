"""Privileged DEV-only bootstrap via the official migration Lambda, never HTTP.

Synthetic fixture provisioning and application password setup are separate from
the normal read-only application role. No secrets are accepted in event payloads.
"""
import json
import os
import re
from uuid import UUID

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
